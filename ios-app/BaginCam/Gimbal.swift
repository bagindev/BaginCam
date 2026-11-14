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
    private var started = false

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
            Log.camera.info("Tombol: controller tersambung (\(c.vendorName ?? "?", privacy: .public), \(c.productCategory, privacy: .public))")
            self?.attach(c)
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            Log.camera.info("Tombol: keyboard Bluetooth terputus")
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in
            Log.camera.info("Tombol: controller terputus")
        }
        if let kb = GCKeyboard.coalesced { attach(kb) }
        GCController.controllers().forEach { attach($0) }
    }

    private func attach(_ kb: GCKeyboard) {
        kb.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
            guard pressed else { return }
            let a = Self.map(code)
            Log.camera.info("Tombol: keyboard kode \(code.rawValue, privacy: .public) -> \(a?.rawValue ?? "tidak dipakai", privacy: .public)")
            if let a { DispatchQueue.main.async { self?.handler?(a, "keyboard \(code.rawValue)") } }
        }
    }

    private func attach(_ c: GCController) {
        c.physicalInputProfile.valueDidChangeHandler = { [weak self, weak c] _, element in
            guard let b = element as? GCControllerButtonInput, b.isPressed else {
                if let d = element as? GCControllerDirectionPad {
                    Log.camera.info("Tombol: controller \(element.localizedName ?? "?", privacy: .public) x \(d.xAxis.value, privacy: .public) y \(d.yAxis.value, privacy: .public)")
                }
                return
            }
            let name = element.localizedName ?? element.aliases.first ?? "?"
            Log.camera.info("Tombol: controller tombol \(name, privacy: .public)")
            // pemetaan awal: A / tombol utama = shutter; disesuaikan setelah log dicek
            if b === c?.extendedGamepad?.buttonA || b === c?.microGamepad?.buttonA {
                DispatchQueue.main.async { self?.handler?(.shutter, "controller \(name)") }
            }
        }
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
