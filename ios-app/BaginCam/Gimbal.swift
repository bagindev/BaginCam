import AVFoundation
import CoreImage
import GameController
import SwiftUI
import Vision

// v0.21: Mode Gimbal (DJI Osmo Mobile 7P dll.)
// Motor / mode gimbal tidak bisa dikontrol app (SDK DJI tertutup, OM 7P tanpa Apple DockKit). Yang bisa:
// - tombol gimbal yang dikirim lewat Bluetooth (seperti tombol volume / remote / keyboard) -> aksi app
// - panduan tracking (modul DJI melacak sendiri; app menampilkan apakah subjek di tengah)
// Semua sinyal tombol dicatat di log supaya pemetaan bisa disesuaikan setelah "cek".

enum GimbalAction: String {
    case shutter = "shutter", zoomIn = "zoom +", zoomOut = "zoom -", flip = "ganti kamera", pause = "jeda/lanjut"
}

/// tombol dari gimbal / remote Bluetooth / keyboard / game controller (main thread)
final class HardwareInput {
    static let shared = HardwareInput()
    var handler: ((GimbalAction, String) -> Void)?
    /// v0.22.1: zoom halus dari roda gimbal — factor per tick (mis. 1.01 zoom in, 0.99 zoom out)
    var onZoom: ((CGFloat) -> Void)?
    /// v0.22.1: dipanggil saat controller (gimbal/remote) tersambung — (vendorName, productCategory)
    var onControllerConnect: ((String, String) -> Void)?
    /// v0.22.1: dipanggil saat controller terputus
    var onControllerDisconnect: (() -> Void)?
    private var started = false

    // MARK: - deteksi zoom dari event volume (roda gimbal OM 7P)
    private var lastVolumeTime: CFTimeInterval = 0
    private var volumeCount = 0
    private var volumeIsPrimary = true
    private var pendingShutter: DispatchWorkItem?

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            guard let kb = n.object as? GCKeyboard else { return }
            Log.camera.info("Tombol: keyboard Bluetooth tersambung (\(kb.vendorName ?? "?", privacy: .public))")
            self?.attach(kb)
        }
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            guard let c = n.object as? GCController else { return }
            let vendor = c.vendorName ?? "?"
            let cat = c.productCategory
            Log.camera.info("Tombol: controller tersambung (\(vendor, privacy: .public), \(cat, privacy: .public))")
            self?.attach(c)
            self?.onControllerConnect?(vendor, cat)
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            Log.camera.info("Tombol: keyboard Bluetooth terputus")
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Log.camera.info("Tombol: controller terputus")
            self?.onControllerDisconnect?()
        }
        if let kb = GCKeyboard.coalesced { attach(kb) }
        GCController.controllers().forEach { attach($0) }
        startVolumeMonitor()
    }

    /// true kalau ada controller tersambung sekarang
    var hasController: Bool { !GCController.controllers().isEmpty }

    private var volumeObserver: NSKeyValueObservation?
    private var lastVolume: Float = -1
    /// set true dari luar saat gimbalMode aktif — baru pakai volume monitor untuk zoom
    var gimbalActive = false

    private func startVolumeMonitor() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        lastVolume = session.outputVolume
        volumeObserver = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, self.gimbalActive, let vol = change.newValue else { return }
            let diff = vol - self.lastVolume
            self.lastVolume = vol
            guard abs(diff) > 0.001 else { return }
            let factor: CGFloat = diff > 0 ? 1.06 : (1.0 / 1.06)
            Log.camera.info("Tombol: volume KVO \(diff > 0 ? "up" : "down", privacy: .public) (\(vol, privacy: .public))")
            DispatchQueue.main.async { self.onZoom?(factor) }
        }
    }

    /// Dipanggil dari AVCaptureEventInteraction saat event volume masuk (.ended).
    /// Logika: event tunggal = shutter, 2x cepat arah sama = zoom, 2x cepat beda arah = flip kamera.
    /// isPrimary: true = volume down, false = volume up.
    func volumeEvent(isPrimary: Bool) {
        let now = CACurrentMediaTime()
        let gap = now - lastVolumeTime
        lastVolumeTime = now

        pendingShutter?.cancel()
        pendingShutter = nil

        if gap < 0.4 {
            volumeCount += 1
        } else {
            volumeCount = 1
            volumeIsPrimary = isPrimary
        }

        if volumeCount >= 2 {
            if volumeIsPrimary != isPrimary {
                // arah berubah (down lalu up, atau sebaliknya) → flip kamera
                volumeCount = 0
                Log.camera.info("Tombol: volume double-tap beda arah -> flip kamera")
                handler?(.flip, "volume double-tap flip")
            } else {
                // arah sama berturut → zoom
                let factor: CGFloat = volumeIsPrimary ? (1.0 / 1.08) : 1.08
                onZoom?(factor)
                Log.camera.info("Tombol: volume zoom \(self.volumeIsPrimary ? "out" : "in", privacy: .public) (x\(self.volumeCount, privacy: .public))")
            }
            return
        }

        let w = DispatchWorkItem { [weak self] in
            self?.pendingShutter = nil
            Log.camera.info("Tombol: volume -> shutter (primary=\(isPrimary, privacy: .public))")
            self?.handler?(.shutter, isPrimary ? "tombol primer" : "tombol sekunder")
        }
        pendingShutter = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func attach(_ kb: GCKeyboard) {
        kb.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
            guard pressed else { return }
            let a = Self.map(code)
            Log.camera.info("Tombol: keyboard kode \(code.rawValue, privacy: .public) -> \(a?.rawValue ?? "tidak dipakai", privacy: .public)")
            if let a { DispatchQueue.main.async { self?.handler?(a, "keyboard \(code.rawValue)") } }
        }
    }

    private var zoomTimer: Timer?

    private func attach(_ c: GCController) {
        c.physicalInputProfile.valueDidChangeHandler = { [weak self, weak c] _, element in
            // direction pad / roda zoom gimbal -> zoom halus berkelanjutan
            if let d = element as? GCControllerDirectionPad {
                let y = d.yAxis.value  // +1 zoom in, -1 zoom out (OM 7P roda zoom)
                let x = d.xAxis.value
                let val = abs(y) >= abs(x) ? y : x
                DispatchQueue.main.async { self?.handleZoomAxis(val) }
                return
            }
            guard let b = element as? GCControllerButtonInput, b.isPressed else { return }
            let name = element.localizedName ?? element.aliases.first ?? "?"
            let aliases = element.aliases.joined(separator: ",")
            Log.camera.info("Tombol: controller tombol \(name, privacy: .public) aliases=[\(aliases, privacy: .public)]")
            let gp = c?.extendedGamepad
            let mgp = c?.microGamepad
            let action: GimbalAction?
            if b === gp?.buttonA || b === mgp?.buttonA || b === gp?.rightTrigger {
                action = .shutter
            } else if b === gp?.buttonB || b === gp?.leftShoulder || b === gp?.leftTrigger {
                action = .flip
            } else if b === gp?.buttonX || b === gp?.buttonY || b === gp?.rightShoulder {
                action = .pause
            } else {
                action = Self.guessAction(name: name, aliases: aliases)
            }
            if let action {
                Log.camera.info("Tombol: controller -> \(action.rawValue, privacy: .public)")
                DispatchQueue.main.async { self?.handler?(action, "controller \(name)") }
            }
        }
    }

    private func handleZoomAxis(_ value: Float) {
        zoomTimer?.invalidate()
        zoomTimer = nil
        let dead: Float = 0.12
        guard abs(value) > dead else { return }
        let speed = CGFloat(value)  // -1..+1
        let tick: TimeInterval = 0.04  // 25 fps
        zoomTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            // faktor per tick: proporsional ke posisi roda, ~1.005–1.03 per 40ms
            let f: CGFloat = 1.0 + CGFloat(speed) * 0.015
            DispatchQueue.main.async { self?.onZoom?(f) }
        }
    }

    static func guessAction(name: String, aliases: String) -> GimbalAction? {
        let low = (name + " " + aliases).lowercased()
        if low.contains("switch") || low.contains("flip") { return .flip }
        if low.contains("record") || low.contains("shutter") || low.contains("capture") { return .shutter }
        if low.contains("pause") { return .pause }
        return nil
    }

    /// pemetaan tombol keyboard umum remote Bluetooth / gimbal
    static func map(_ k: GCKeyCode) -> GimbalAction? {
        switch k {
        case .upArrow, .rightArrow, .equalSign, .keypadPlus, .pageUp: return .zoomIn
        case .downArrow, .leftArrow, .hyphen, .keypadHyphen, .pageDown: return .zoomOut
        case .returnOrEnter, .keypadEnter, .spacebar: return .shutter
        case .tab, .keyF, .keyC: return .flip
        case .keyP: return .pause
        default: return nil
        }
    }
}

/// panduan tracking: posisi subjek (wajah, kalau tidak ada badan) di preview, ~2x per detik
final class GimbalGuide: ObservableObject {
    /// kiri-atas, ternormalisasi ke preview
    @Published private(set) var subject: CGRect?
    private let queue = DispatchQueue(label: "bagincam.gimbal", qos: .utility)
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var busy = false      // main
    private var count = 0         // main
    private var missing = 0       // main

    /// main (dari draw preview, tiap 8 frame)
    func push(_ image: CIImage) {
        count += 1
        guard count % 2 == 0, !busy else { return }
        busy = true
        queue.async {
            let r = Self.detect(image, ctx: self.ctx)
            DispatchQueue.main.async {
                self.busy = false
                if let r {
                    self.missing = 0
                    if r != self.subject { self.subject = r }
                } else {
                    self.missing += 1
                    if self.missing >= 3 && self.subject != nil { self.subject = nil }
                }
            }
        }
    }

    func reset() {
        missing = 0
        if subject != nil { subject = nil }
    }

    private static func detect(_ image: CIImage, ctx: CIContext) -> CGRect? {
        let e = image.extent
        let k = min(1, 480 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = ctx.createCGImage(small, from: small.extent) else { return nil }
        let face = VNDetectFaceRectanglesRequest()
        let human = VNDetectHumanRectanglesRequest()
        human.upperBodyOnly = true
        try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([face, human])
        func area(_ r: CGRect) -> CGFloat { r.width * r.height }
        let f = (face.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox).max { area($0) < area($1) }
        let h = (human.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox).max { area($0) < area($1) }
        guard let b = f ?? h else { return nil }
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }
}

// MARK: - v0.22: Face Tracking Digital (crop-follow mirip Center Stage)
// Sumber 4K / 48MP, keluaran 1080p: crop window mengikuti wajah, gerakan halus.
// Bisa dipakai saat rekam video maupun preview. Crop diterapkan di VideoRecorder.

final class FaceTracker: ObservableObject {
    /// crop rect ternormalisasi (0..1, origin = kiri-atas) yang dikirim ke perekam
    @Published private(set) var cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    @Published private(set) var faceDetected = false

    private let queue = DispatchQueue(label: "bagincam.facetrack", qos: .userInteractive)
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var busy = false
    private var count = 0
    private var smoothX: CGFloat = 0.5
    private var smoothY: CGFloat = 0.4
    private var missingCount = 0

    /// rasio output/sumber (mis. 1080/2160 = 0.5 untuk 4K->1080p), diset sebelum mulai
    var outputRatio: CGFloat = 0.5

    /// smoothing factor (0 = instant, 1 = tidak bergerak). 0.85 = halus tapi responsif
    private let alpha: CGFloat = 0.85

    func push(_ image: CIImage) {
        count += 1
        guard count % 2 == 0, !busy else { return }
        busy = true
        let ratio = outputRatio
        queue.async {
            let face = self.detectFace(image)
            DispatchQueue.main.async {
                self.busy = false
                if let face {
                    self.missingCount = 0
                    self.faceDetected = true
                    // target: tengah wajah -> tengah crop window
                    let tx = face.midX
                    let ty = face.midY
                    self.smoothX = self.smoothX * self.alpha + tx * (1 - self.alpha)
                    self.smoothY = self.smoothY * self.alpha + ty * (1 - self.alpha)
                } else {
                    self.missingCount += 1
                    if self.missingCount > 8 {
                        self.faceDetected = false
                        // drift kembali ke tengah saat wajah hilang
                        self.smoothX = self.smoothX * 0.97 + 0.5 * 0.03
                        self.smoothY = self.smoothY * 0.97 + 0.4 * 0.03
                    }
                }
                // hitung crop window (ratio x ratio ukuran sumber)
                let cw = ratio, ch = ratio
                let cx = min(max(self.smoothX - cw / 2, 0), 1 - cw)
                let cy = min(max(self.smoothY - ch / 2, 0), 1 - ch)
                let r = CGRect(x: cx, y: cy, width: cw, height: ch)
                if r != self.cropRect { self.cropRect = r }
            }
        }
    }

    func reset() {
        smoothX = 0.5; smoothY = 0.4; missingCount = 0; faceDetected = false
        cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    }

    private func detectFace(_ image: CIImage) -> CGRect? {
        let e = image.extent
        let k = min(1, 480 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = ctx.createCGImage(small, from: small.extent) else { return nil }
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])
        guard let best = (req.results ?? []).filter({ $0.confidence > 0.5 })
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        else { return nil }
        let b = best.boundingBox
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }
}

/// overlay face tracking: kotak wajah + label
struct FaceTrackOverlay: View {
    @ObservedObject var tracker: FaceTracker

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let r = tracker.cropRect
            let box = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
            ZStack {
                // crop window
                RoundedRectangle(cornerRadius: 8).stroke(
                    tracker.faceDetected ? Color.cyan : Color.white.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: tracker.faceDetected ? [] : [6, 4])
                )
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                // label
                Text(tracker.faceDetected ? "Face Track" : "Face Track: cari wajah")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(tracker.faceDetected ? .cyan : .white.opacity(0.6))
                    .position(x: box.midX, y: box.minY - 14)
            }
            .animation(.easeOut(duration: 0.15), value: tracker.cropRect)
        }
        .allowsHitTesting(false)
    }
}

/// kotak tengah + penanda subjek. Hijau = subjek di tengah (tracking modul DJI bekerja)
struct GimbalOverlay: View {
    @ObservedObject var guide: GimbalGuide

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let box = CGRect(x: w * 0.3, y: h * 0.26, width: w * 0.4, height: h * 0.34)
            let s = guide.subject.map { CGRect(x: $0.minX * w, y: $0.minY * h, width: $0.width * w, height: $0.height * h) }
            let inside = s.map { box.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
            let col: Color = s == nil ? .white.opacity(0.5) : (inside ? .green : .orange)
            ZStack {
                Path { p in p.addRoundedRect(in: box, cornerSize: CGSize(width: 10, height: 10)) }
                    .stroke(col, style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                if let s {
                    RoundedRectangle(cornerRadius: 6).stroke(col, lineWidth: 2)
                        .frame(width: s.width, height: s.height)
                        .position(x: s.midX, y: s.midY)
                    if !inside {
                        Path { p in
                            p.move(to: CGPoint(x: s.midX, y: s.midY))
                            p.addLine(to: CGPoint(x: box.midX, y: box.midY))
                        }
                        .stroke(col, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
                }
                Text(s == nil ? "Gimbal: cari subjek" : (inside ? "Gimbal: subjek di tengah" : "Gimbal: subjek keluar tengah"))
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(col)
                    .position(x: box.midX, y: box.minY - 14)
            }
            .animation(.easeOut(duration: 0.3), value: guide.subject)
        }
        .allowsHitTesting(false)
    }
}
