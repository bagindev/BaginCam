import AVKit
import CoreMotion
import SwiftUI
import MetalKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Render frame kamera ke layar dengan Metal (Core Image di GPU):
/// digital zoom -> LUT -> focus peaking -> zebra, plus histogram luminans.
/// v0.41.4: digambar di antrean sendiri tiap ada frame kamera baru (CAMetalLayer.nextDrawable), BUKAN dari main
/// thread. Dulu (display link di main) preview turun ke ~4 fps selama menu / laci iOS terbuka (rekam layar 18 Nov
/// 12:21, frame 61-122 sama) karena main thread sibuk menggambar menu + blur. Properti diisi dari main (nilai
/// sederhana); callback ke UI (histogram, AI komposisi, peta zoom) dikirim ke main.
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let ciContext: CIContext
    private let lock = NSLock()
    private var latest: CIImage?
    private let renderQueue = DispatchQueue(label: "bagincam.preview", qos: .userInteractive)
    private var rendering = false                 // dijaga lock
    private weak var layer: CAMetalLayer?         // dijaga lock
    private var lastRender = 0.0                  // renderQueue
    private var failCount = 0, firstDrawn = false // renderQueue
    /// batas fps preview (panas kritis: 20)
    var fpsLimit = 30

    var lutFilter: CIFilter?
    /// beku = frame terakhir tetap tampil (saat capture mengganti zoom/lensa di belakang layar)
    var frozen = false
    var zoom: CGFloat = 1
    var zebra = false
    var zebraLevel: Float = 0.95
    var peaking = false
    var peakColor = CIColor(red: 1, green: 0.15, blue: 0.1)
    /// penajaman zoom digital video (sama dengan yang direkam)
    var sharpen: Float = 0
    private let sharpenFilter = CIFilter.sharpenLuminance()
    var histogramEnabled = true
    /// 64 bin luminans ternormalisasi 0..1 (dipanggil di main ~5x/detik)
    var onHistogram: (([Float]) -> Void)?
    /// v0.13: frame ukuran layar (sebelum LUT) ~4x/detik untuk AI Komposisi
    var onAnalysis: ((CIImage) -> Void)?
    /// v0.39: peta zoom - gambar acuan diambil dari frame yang tampil
    weak var navigator: ZoomNavigator?
    private var navSentAt = 0.0          // antrean render

    private var frameCounter = 0
    // v0.40.2: statistik render preview (log tiap 10 s)
    private var statStart = CACurrentMediaTime()
    private var statFrames = 0
    private var statCPU = 0.0
    private var statGPU = 0.0
    private var statGPUn = 0
    private let statLock = NSLock()
    private weak var lastDrawn: CIImage?       // v0.15: frame sama -> tidak dirender ulang (hemat GPU/panas)
    private var histBitmap = [Float](repeating: 0, count: 64 * 4)

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    /// layer tujuan (main, dari PreviewMTKView)
    func attach(_ l: CAMetalLayer) {
        lock.lock(); layer = l; lock.unlock()
        Log.camera.notice("Preview: layer dipasang \(Int(l.drawableSize.width), privacy: .public)x\(Int(l.drawableSize.height), privacy: .public)")
    }

    /// v0.41.5: lepas HANYA bila layer itu yang sedang dipakai. Build 104: SwiftUI membuat tampilan preview baru
    /// (mis. app dibuka di VIDEO) lalu membongkar yang lama -> layer baru ikut dilepas -> preview hitam, tidak ada
    /// satu pun log "Preview:" (screenshot 18 Nov 12:38).
    func detach(_ l: CAMetalLayer) {
        lock.lock(); if layer === l { layer = nil }; lock.unlock()
    }

    /// Dipanggil dari antrean video kamera. Frame baru langsung digambar di antrean preview.
    func push(_ image: CIImage) {
        lock.lock()
        if frozen { lock.unlock(); return }
        latest = image
        let start = !rendering && layer != nil
        if start { rendering = true }
        lock.unlock()
        if start { renderQueue.async { self.renderLoop() } }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {}

    /// renderQueue: gambar frame terbaru sampai tidak ada yang baru
    private func renderLoop() {
        while true {
            lock.lock()
            let frame = latest, l = layer
            if frame == nil || frame === lastDrawn || l == nil {
                rendering = false
                lock.unlock()
                return
            }
            lock.unlock()
            // batas fps (frame kamera bisa 60 fps saat merekam 60p)
            let minGap = 1.0 / Double(max(fpsLimit, 1)) - 0.004
            let now = CACurrentMediaTime()
            if now - lastRender < minGap { Thread.sleep(forTimeInterval: minGap - (now - lastRender)) }
            lastRender = CACurrentMediaTime()
            autoreleasepool { render(frame!, layer: l!) }
        }
    }

    private func render(_ frame: CIImage, layer: CAMetalLayer) {
        let ds = layer.drawableSize
        guard ds.width > 8, ds.height > 8, let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else {
            lastDrawn = frame
            failCount += 1
            if failCount == 1 || failCount % 300 == 0 {
                Log.camera.error("! Preview: gagal menggambar (\(self.failCount, privacy: .public)x), ukuran \(Int(ds.width), privacy: .public)x\(Int(ds.height), privacy: .public)")
            }
            return
        }
        if !firstDrawn {
            firstDrawn = true
            Log.camera.notice("Preview: frame pertama digambar \(Int(ds.width), privacy: .public)x\(Int(ds.height), privacy: .public)")
        }
        var image = frame
        let tDraw = CACurrentMediaTime()

        // digital zoom (crop tengah) - sama persis dengan crop AI Zoom saat memotret
        if zoom > 1.001 {
            let e = image.extent
            let cw = e.width / zoom, ch = e.height / zoom
            image = image.cropped(to: CGRect(x: e.midX - cw / 2, y: e.midY - ch / 2, width: cw, height: ch))
        }
        // v0.12.1: perkecil ke ukuran layar DULU (4K = 8 MP -> ~1-2 MP), baru LUT / peaking / zebra / histogram.
        // Dulu semua filter jalan di 4K penuh 30x per detik -> GPU kerja keras, HP cepat panas saat video.
        do {
            let e = image.extent
            let k = max(ds.width / e.width, ds.height / e.height)
            if k < 0.95 {
                image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: k, y: k), highQualityDownsample: true)
                image = image.cropped(to: CGRect(x: 0, y: 0, width: (e.width * k).rounded(.down), height: (e.height * k).rounded(.down)))
            }
        }
        let extent = image.extent
        if let cb = onAnalysis, frameCounter % 8 == 0 { let im = image; DispatchQueue.main.async { cb(im) } }

        // luminans sinyal (sebelum LUT) untuk zebra / peaking / histogram
        var luma: CIImage?
        if zebra || peaking || histogramEnabled {
            let mono = CIFilter.colorControls()
            mono.inputImage = image
            mono.saturation = 0
            luma = mono.outputImage
        }

        if let f = lutFilter {
            f.setValue(image, forKey: kCIInputImageKey)
            if let out = f.outputImage { image = out }
        }

        if sharpen > 0.01 {
            sharpenFilter.inputImage = image
            sharpenFilter.sharpness = sharpen
            sharpenFilter.radius = 1.6
            if let out = sharpenFilter.outputImage?.cropped(to: extent) { image = out }
        }

        // v0.42.7: frame ke peta zoom paling sering ~3x/detik (dulu tiap frame dikirim ke main thread)
        if let nav = navigator, CACurrentMediaTime() - navSentAt > 0.3 {
            let im = image, ctx = ciContext
            if nav.wantsRef {
                navSentAt = CACurrentMediaTime()
                DispatchQueue.main.async { nav.offer(im, context: ctx) }
            } else if nav.wantsProbe {
                // peta zoom dicocokkan dengan preview (koreksi posisi / deteksi acuan basi)
                navSentAt = CACurrentMediaTime()
                DispatchQueue.main.async { nav.probe(im, context: ctx) }
            }
        }

        if peaking, let l = luma {
            let edges = CIFilter.edges()
            edges.inputImage = l
            edges.intensity = 4
            let th = CIFilter.colorThreshold()
            th.inputImage = edges.outputImage
            th.threshold = 0.35
            if let mask = th.outputImage?.cropped(to: extent) {
                let red = CIImage(color: peakColor).cropped(to: extent)
                image = blend(red, over: image, mask: mask)
            }
        }

        if zebra, let l = luma {
            let th = CIFilter.colorThreshold()
            th.inputImage = l
            th.threshold = zebraLevel
            let stripes = CIFilter.stripesGenerator()
            stripes.color0 = CIColor(red: 0, green: 0, blue: 0)
            stripes.color1 = CIColor(red: 1, green: 1, blue: 1)
            stripes.width = Float(max(4, extent.width / 120))
            stripes.sharpness = 1
            if let mask = th.outputImage?.cropped(to: extent),
               let st = stripes.outputImage?.transformed(by: CGAffineTransform(rotationAngle: .pi / 4)).cropped(to: extent) {
                image = blend(st, over: image, mask: mask)
            }
        }

        frameCounter += 1
        if histogramEnabled, frameCounter % 6 == 0, let l = luma { computeHistogram(l) }

        // aspect-fill ke ukuran layar
        let scale = max(ds.width / extent.width, ds.height / extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: (ds.width - image.extent.width) / 2 - image.extent.origin.x,
            y: (ds.height - image.extent.height) / 2 - image.extent.origin.y))

        let dest = CIRenderDestination(width: Int(ds.width), height: Int(ds.height),
                                       pixelFormat: layer.pixelFormat,
                                       commandBuffer: commandBuffer,
                                       mtlTextureProvider: { drawable.texture })
        _ = try? ciContext.startTask(toRender: image, from: CGRect(origin: .zero, size: ds),
                                     to: dest, at: .zero)
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self, cb.gpuEndTime > cb.gpuStartTime else { return }
            self.statLock.lock()
            self.statGPU += cb.gpuEndTime - cb.gpuStartTime
            self.statGPUn += 1
            self.statLock.unlock()
        }
        commandBuffer.commit()
        lastDrawn = frame
        statFrames += 1
        statCPU += CACurrentMediaTime() - tDraw
        let el = CACurrentMediaTime() - statStart
        if el >= 10 {
            statLock.lock()
            let gpu = statGPUn > 0 ? statGPU / Double(statGPUn) * 1000 : 0
            statGPU = 0; statGPUn = 0
            statLock.unlock()
            let fps = Double(statFrames) / el, cpu = statCPU / Double(max(statFrames, 1)) * 1000
            let on = [lutFilter != nil ? "LUT" : nil, sharpen > 0.01 ? "tajam" : nil, histogramEnabled ? "histogram" : nil,
                      zebra ? "zebra" : nil, peaking ? "peaking" : nil, navigator?.wantsRef == true ? "peta" : nil].compactMap { $0 }
            let dsw = Int(ds.width), dsh = Int(ds.height), onTxt = on.joined(separator: ", ")
            DispatchQueue.main.async {
            let ui = Double(BodyCounter.take()) / el
            Log.camera.notice("Preview: \(fps, format: .fixed(precision: 1), privacy: .public) fps, UI \(ui, format: .fixed(precision: 1), privacy: .public)x/s, CPU \(cpu, format: .fixed(precision: 1), privacy: .public) ms, GPU \(gpu, format: .fixed(precision: 1), privacy: .public) ms per frame, \(dsw, privacy: .public)x\(dsh, privacy: .public), aktif [\(onTxt, privacy: .public)], suhu \(ProcessInfo.processInfo.thermalState.rawValue, privacy: .public), digambar di antrean sendiri")
            }
            statStart = CACurrentMediaTime()
            statFrames = 0
            statCPU = 0
        }
    }

    private func blend(_ top: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let b = CIFilter.blendWithMask()
        b.inputImage = top
        b.backgroundImage = background
        b.maskImage = mask
        return b.outputImage ?? background
    }

    private func computeHistogram(_ luma: CIImage) {
        let small = luma.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let h = CIFilter.areaHistogram()
        h.inputImage = small
        h.extent = small.extent
        h.count = 64
        h.scale = 1
        guard let out = h.outputImage else { return }
        histBitmap.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            ciContext.render(out, toBitmap: base, rowBytes: 64 * 16,
                             bounds: CGRect(x: 0, y: 0, width: 64, height: 1),
                             format: .RGBAf, colorSpace: nil)
        }
        var bins = (0..<64).map { histBitmap[$0 * 4] }
        // akar supaya bin kecil tetap terlihat
        bins = bins.map { $0.squareRoot() }
        if let m = bins.max(), m > 0 { bins = bins.map { $0 / m } }
        if let cb = onHistogram { DispatchQueue.main.async { cb(bins) } }
    }
}

struct MetalPreview: UIViewRepresentable {
    let renderer: PreviewRenderer
    /// tombol volume / Camera Control ditekan (iOS 17.2+)
    var onHardwareShutter: ((String) -> Void)? = nil
    /// v0.22.1: event volume mentah — (isPrimary, phase "began"/"ended")
    var onVolumeEvent: ((Bool, String) -> Void)? = nil
    var fps = 30

    func makeUIView(context: Context) -> MTKView {
        let v = PreviewMTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false          // wajib supaya Core Image bisa menulis ke drawable
        v.delegate = renderer
        v.isPaused = true                  // v0.41.4: tidak pakai pewaktu MTKView - digambar dari antrean preview
        v.enableSetNeedsDisplay = false
        v.renderer = renderer
        renderer.fpsLimit = fps
        v.backgroundColor = .black
        if #available(iOS 17.2, *), let action = onHardwareShutter {
            let volEvent = onVolumeEvent
            let interaction = AVCaptureEventInteraction(primary: { event in
                let ph = event.phase == .began ? "began" : event.phase == .ended ? "ended" : "other"
                volEvent?(true, ph)
                if event.phase == .ended { action("tombol primer") }
            }, secondary: { event in
                let ph = event.phase == .began ? "began" : event.phase == .ended ? "ended" : "other"
                volEvent?(false, ph)
                if event.phase == .ended { action("tombol sekunder") }
            })
            v.addInteraction(interaction)
        }
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        if renderer.fpsLimit != fps { renderer.fpsLimit = fps }
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        if let v = uiView as? PreviewMTKView, let l = v.layer as? CAMetalLayer { v.renderer?.detach(l) }
    }
}

/// v0.41.4: MTKView hanya wadah CAMetalLayer; gambar dikirim PreviewRenderer dari antrean preview.
/// (v0.41.2 memakai CADisplayLink di main - tetap tersendat saat menu karena main thread sibuk.)
final class PreviewMTKView: MTKView {
    weak var renderer: PreviewRenderer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let l = layer as? CAMetalLayer else { return }
        if window == nil { renderer?.detach(l) } else { ensureSize(); renderer?.attach(l) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ensureSize()
    }

    /// MTKView di-pause: pastikan ukuran drawable mengikuti ukuran tampilan
    private func ensureSize() {
        guard let l = layer as? CAMetalLayer else { return }
        let want = CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
        if want.width > 0, want.height > 0, l.drawableSize != want { l.drawableSize = want }
    }
}

/// v0.40.4: penghitung hitung ulang layar utama (main thread) - untuk log
enum BodyCounter {
    private static var n = 0
    static func tick() { n += 1 }
    static func take() -> Int { defer { n = 0 }; return n }
}

/// v0.40.4: bin histogram dipegang objek sendiri - dulu @State di ContentView -> layar dihitung ulang 5x/detik di PRO
final class HistogramState: ObservableObject {
    @Published var bins: [Float] = []
}

struct HistogramBox: View {
    @ObservedObject var s: HistogramState
    var body: some View {
        if !s.bins.isEmpty { HistogramView(bins: s.bins) }
    }
}

/// Histogram kecil di pojok preview.
struct HistogramView: View {
    let bins: [Float]
    var body: some View {
        GeometryReader { g in
            Path { p in
                guard bins.count > 1 else { return }
                let w = g.size.width, h = g.size.height
                p.move(to: CGPoint(x: 0, y: h))
                for (i, v) in bins.enumerated() {
                    p.addLine(to: CGPoint(x: w * CGFloat(i) / CGFloat(bins.count - 1), y: h * (1 - CGFloat(v))))
                }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
            }
            .fill(.white.opacity(0.75))
        }
        .frame(width: 110, height: 44)
        .padding(4)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Garis bantu komposisi 3x3 (rule of thirds).
struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
        }
    }
}

/// Waterpass: kemiringan HP (roll) dari CoreMotion.
/// v0.39: kemiringan dipisah dari LevelMonitor. Dulu `roll` diterbitkan 20x/detik oleh LevelMonitor yang dipegang
/// ContentView -> SELURUH layar dihitung ulang 20x/detik di main thread, tempat preview Metal juga digambar
/// (preview & zoom tersendat, HP lebih panas). Sekarang hanya garis waterpass yang mengamati nilai ini.
final class RollState: ObservableObject {
    @Published var roll: Double = 0
}

final class LevelMonitor: ObservableObject {
    let rollState = RollState()
    /// derajat, 0 = datar (potret / lanskap)
    var roll: Double { rollState.roll }
    /// dipanggil tiap pembaruan gerak (main) - AI Komposisi
    var onRoll: ((Double) -> Void)?
    @Published private(set) var flat = false          // HP rebah (menghadap atas/bawah)
    /// HP diam (tripod / disandarkan) > ~1 detik: putaran gyro sangat kecil (untuk mode MALAM)
    @Published private(set) var steady = false
    /// v0.15: sudut rotasi capture dari gravitasi (90 potret, 0 / 180 lanskap, 270 terbalik) - tidak bergantung
    /// orientasi UI / Rotation Lock (RotationCoordinator selalu 90 bila Rotation Lock nyala)
    @Published private(set) var captureAngle: CGFloat = 90
    /// salinan untuk dibaca dari antrean lain
    private(set) var angleNow: CGFloat = 90
    private var rotSmooth = 1.0
    /// putaran gyro rata-rata (rad/s) - untuk log
    var rotationLevel: Double { rotSmooth }
    private var steadyTicks = 0
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            let g = m.gravity
            let r = m.rotationRate
            self.rotSmooth = 0.8 * self.rotSmooth + 0.2 * sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
            self.steadyTicks = self.rotSmooth < 0.035 ? self.steadyTicks + 1 : 0
            let st = self.steadyTicks >= 16
            if st != self.steady { self.steady = st }
            let fl = abs(g.z) > 0.85
            if fl != self.flat { self.flat = fl }       // v0.40.4: dulu diisi 20x/detik -> layar dihitung ulang 20x/detik
            var a = atan2(g.x, -g.y) * 180 / .pi          // potret tegak = 0
            if !fl {
                let q = (a / 90).rounded() * 90                     // kuadran terdekat
                if abs(a - q) < 35 {                                // histeresis: hanya bila jelas
                    var ang = 90 + q                                // 0 -> 90, -90 -> 0, 90 -> 180, 180 -> 270
                    if ang < 0 { ang += 360 }
                    if ang >= 360 { ang -= 360 }
                    let c = CGFloat(ang)
                    if c != self.angleNow { self.angleNow = c; self.captureAngle = c }
                }
            }
            // pegang lanskap: ukur terhadap 90 derajat terdekat
            if a > 45 && a <= 135 { a -= 90 } else if a < -45 && a >= -135 { a += 90 } else if a > 135 { a -= 180 } else if a < -135 { a += 180 }
            if abs(a - self.rollState.roll) >= 0.2 { self.rollState.roll = a }
            self.onRoll?(a)
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

/// Garis waterpass di tengah preview (kuning bila datar +-1 derajat).
struct LevelOverlay: View {
    @ObservedObject var level: LevelMonitor
    @ObservedObject var rs: RollState
    init(level: LevelMonitor) {
        self.level = level
        self.rs = level.rollState
    }
    var body: some View {
        let ok = abs(rs.roll) < 1
        GeometryReader { g in
            ZStack {
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 40, height: 1)
                    .position(x: g.size.width / 2 - 70, y: g.size.height / 2)
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 40, height: 1)
                    .position(x: g.size.width / 2 + 70, y: g.size.height / 2)
                Rectangle().fill(ok ? Color.yellow : Color.white)
                    .frame(width: 100, height: ok ? 2 : 1.5)
                    .rotationEffect(.degrees(-rs.roll))
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                if !ok {
                    Text(String(format: "%.0f°", rs.roll)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.white).position(x: g.size.width / 2, y: g.size.height / 2 + 14)
                }
            }
            .opacity(level.flat || abs(rs.roll) > 30 ? 0 : 1)
        }
        .allowsHitTesting(false)
    }
}
