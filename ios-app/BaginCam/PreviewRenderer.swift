import AVKit
import CoreMotion
import SwiftUI
import MetalKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Render frame kamera ke layar dengan Metal (Core Image di GPU):
/// digital zoom -> LUT -> focus peaking -> zebra, plus histogram luminans.
/// Semua properti diakses dari main thread (draw MTKView berjalan di main).
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let ciContext: CIContext
    private let lock = NSLock()
    private var latest: CIImage?

    var lutFilter: CIFilter?
    /// beku = frame terakhir tetap tampil (saat capture mengganti zoom/lensa di belakang layar)
    var frozen = false
    var zoom: CGFloat = 1
    var zebra = false
    var zebraLevel: Float = 0.95
    var peaking = false
    var histogramEnabled = true
    /// 64 bin luminans ternormalisasi 0..1 (dipanggil di main ~5x/detik)
    var onHistogram: (([Float]) -> Void)?

    private var frameCounter = 0
    private var histBitmap = [Float](repeating: 0, count: 64 * 4)

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    /// Dipanggil dari antrean video kamera.
    func push(_ image: CIImage) {
        lock.lock(); if !frozen { latest = image }; lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock(); let frame = latest; lock.unlock()
        guard var image = frame,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        // digital zoom (crop tengah) - sama persis dengan crop AI Zoom saat memotret
        if zoom > 1.001 {
            let e = image.extent
            let cw = e.width / zoom, ch = e.height / zoom
            image = image.cropped(to: CGRect(x: e.midX - cw / 2, y: e.midY - ch / 2, width: cw, height: ch))
        }
        let extent = image.extent

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

        if peaking, let l = luma {
            let edges = CIFilter.edges()
            edges.inputImage = l
            edges.intensity = 4
            let th = CIFilter.colorThreshold()
            th.inputImage = edges.outputImage
            th.threshold = 0.35
            if let mask = th.outputImage?.cropped(to: extent) {
                let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.1)).cropped(to: extent)
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
        let ds = view.drawableSize
        let scale = max(ds.width / extent.width, ds.height / extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: (ds.width - image.extent.width) / 2 - image.extent.origin.x,
            y: (ds.height - image.extent.height) / 2 - image.extent.origin.y))

        let dest = CIRenderDestination(width: Int(ds.width), height: Int(ds.height),
                                       pixelFormat: view.colorPixelFormat,
                                       commandBuffer: commandBuffer,
                                       mtlTextureProvider: { drawable.texture })
        _ = try? ciContext.startTask(toRender: image, from: CGRect(origin: .zero, size: ds),
                                     to: dest, at: .zero)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func blend(_ top: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let b = CIFilter.blendWithMask()
        b.inputImage = top
        b.backgroundImage = background
        b.maskImage = mask
        return b.outputImage ?? background
    }

    private func computeHistogram(_ luma: CIImage) {
        let small = luma.transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
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
        onHistogram?(bins)
    }
}

struct MetalPreview: UIViewRepresentable {
    let renderer: PreviewRenderer
    /// tombol volume / Camera Control ditekan (iOS 17.2+)
    var onHardwareShutter: (() -> Void)? = nil

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false          // wajib supaya Core Image bisa menulis ke drawable
        v.preferredFramesPerSecond = 30
        v.delegate = renderer
        v.backgroundColor = .black
        if #available(iOS 17.2, *), let action = onHardwareShutter {
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .ended { action() }
            }
            v.addInteraction(interaction)
        }
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
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
final class LevelMonitor: ObservableObject {
    @Published private(set) var roll: Double = 0      // derajat, 0 = datar (potret / lanskap)
    @Published private(set) var flat = false          // HP rebah (menghadap atas/bawah)
    /// HP diam (tripod / disandarkan) > ~1 detik: putaran gyro sangat kecil (untuk mode MALAM)
    @Published private(set) var steady = false
    private var rotSmooth = 1.0
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
            self.steadyTicks = self.rotSmooth < 0.02 ? self.steadyTicks + 1 : 0
            let st = self.steadyTicks >= 20
            if st != self.steady { self.steady = st }
            self.flat = abs(g.z) > 0.85
            var a = atan2(g.x, -g.y) * 180 / .pi          // potret tegak = 0
            // pegang lanskap: ukur terhadap 90 derajat terdekat
            if a > 45 && a <= 135 { a -= 90 } else if a < -45 && a >= -135 { a += 90 } else if a > 135 { a -= 180 } else if a < -135 { a += 180 }
            self.roll = a
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

/// Garis waterpass di tengah preview (kuning bila datar +-1 derajat).
struct LevelOverlay: View {
    @ObservedObject var level: LevelMonitor
    var body: some View {
        let ok = abs(level.roll) < 1
        GeometryReader { g in
            ZStack {
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 40, height: 1)
                    .position(x: g.size.width / 2 - 70, y: g.size.height / 2)
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 40, height: 1)
                    .position(x: g.size.width / 2 + 70, y: g.size.height / 2)
                Rectangle().fill(ok ? Color.yellow : Color.white)
                    .frame(width: 100, height: ok ? 2 : 1.5)
                    .rotationEffect(.degrees(-level.roll))
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                if !ok {
                    Text(String(format: "%.0f°", level.roll)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.white).position(x: g.size.width / 2, y: g.size.height / 2 + 14)
                }
            }
            .opacity(level.flat || abs(level.roll) > 30 ? 0 : 1)
        }
        .allowsHitTesting(false)
    }
}
