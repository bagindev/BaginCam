import CoreImage
import CoreMotion
import QuartzCore
import SwiftUI

/// v0.39: peta zoom seperti kamera bawaan (iOS 18 menampilkan gambar lebar + kotak kuning saat zoom jauh).
/// Kamera bawaan memakai aliran kamera kedua secara langsung; di sini lebih hemat: gambar preview terakhir saat zoom
/// masih < 6x disimpan sebagai acuan (tiap ~0,4 s), lalu posisi kotak digeser memakai gyro (putaran HP sejak gambar
/// acuan diambil). Ukuran kotak = zoom acuan / zoom sekarang. Hanya kamera belakang, bukan DUAL.
/// Semua dipanggil di main thread (draw MTKView juga di main).
final class ZoomNavigator: ObservableObject {
    static let showAt: CGFloat = 8          // peta tampil mulai zoom ini
    static let refBelow: CGFloat = 6        // gambar acuan diperbarui selama zoom di bawah ini

    @Published private(set) var visible = false
    /// kotak zoom sekarang di gambar acuan (0..1, kiri-atas)
    @Published private(set) var rect = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
    /// pusat kotak sudah di luar gambar acuan (HP digeser jauh)
    @Published private(set) var outside = false
    private(set) var ref: CGImage?

    var enabled = false { didSet { if enabled != oldValue { refresh() } } }
    private var zoom: CGFloat = 1
    private var fovTan1x = 0.42             // tan(setengah sudut) lebar preview di zoom 1x (diisi CameraManager)
    private var refZoom: CGFloat = 1
    private var refTanW = 0.42, refTanH = 0.75
    private var tiltX = 0.0, tiltY = 0.0    // putaran HP (rad, sumbu perangkat) sejak gambar acuan
    private var lastOffer = 0.0
    private var lastStamp = 0.0
    private let motion = CMMotionManager()

    var wantsRef: Bool { enabled && zoom < Self.refBelow }

    func setZoom(_ z: CGFloat, fovTan1x t: Double) {
        zoom = z
        if t > 0.01 { fovTan1x = t }
        refresh()
    }

    /// gambar yang sedang tampil di layar (sudah di-crop zoom preview & diperkecil ke ukuran layar)
    func offer(_ image: CIImage, context: CIContext) {
        let now = CACurrentMediaTime()
        guard wantsRef, now - lastOffer > 0.4 else { return }
        lastOffer = now
        let e = image.extent
        guard e.width > 8, e.height > 8 else { return }
        let k = min(1, 360 / e.width)
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = context.createCGImage(small, from: small.extent) else { return }
        ref = cg
        refZoom = zoom
        refTanW = fovTan1x / Double(max(zoom, 0.1))
        refTanH = refTanW * Double(e.height / e.width)
        tiltX = 0
        tiltY = 0
    }

    private func refresh() {
        let show = enabled && zoom >= Self.showAt && ref != nil
        if show != visible { visible = show }
        let needMotion = enabled && zoom >= 2
        if needMotion && !motion.isDeviceMotionActive && motion.isDeviceMotionAvailable {
            lastStamp = 0
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
                guard let self, let m else { return }
                let dt = self.lastStamp > 0 ? min(0.1, m.timestamp - self.lastStamp) : 0
                self.lastStamp = m.timestamp
                self.tiltX += m.rotationRate.x * dt
                self.tiltY += m.rotationRate.y * dt
                if self.visible { self.updateRect() }
            }
        } else if !needMotion && motion.isDeviceMotionActive {
            motion.stopDeviceMotionUpdates()
        }
        if show { updateRect() }
    }

    /// putar di sumbu y perangkat (+) = kamera belakang menoleh ke kiri layar; sumbu x (+) = menengadah
    private func updateRect() {
        let f = CGFloat(min(1, Double(refZoom / max(zoom, 0.1))))
        let cx = CGFloat(0.5 - tan(tiltY) / (2 * refTanW))
        let cy = CGFloat(0.5 - tan(tiltX) / (2 * refTanH))
        let out = cx < 0 || cx > 1 || cy < 0 || cy > 1
        if out != outside { outside = out }
        let mx = min(max(cx, f / 2), 1 - f / 2), my = min(max(cy, f / 2), 1 - f / 2)
        let r = CGRect(x: mx - f / 2, y: my - f / 2, width: f, height: f)
        if abs(r.minX - rect.minX) > 0.002 || abs(r.minY - rect.minY) > 0.002 || abs(r.width - rect.width) > 0.002 { rect = r }
    }
}

/// peta kecil di pojok kanan atas preview
struct ZoomNavigatorView: View {
    @ObservedObject var nav: ZoomNavigator

    var body: some View {
        if nav.visible, let ref = nav.ref {
            let r = nav.rect
            // tampilkan sekitar 3x lebar kotak (seperti kamera bawaan), tidak lebih dari gambar acuan
            let rW = min(1, r.width * 3), rH = min(1, r.height * 3)
            let ox = min(max(r.midX - rW / 2, 0), 1 - rW), oy = min(max(r.midY - rH / 2, 0), 1 - rH)
            let aspect = CGFloat(ref.height) / CGFloat(max(ref.width, 1))
            let W: CGFloat = 104
            let H = W * aspect * rH / rW
            let fullW = W / rW, fullH = H / rH
            ZStack(alignment: .topLeading) {
                Image(decorative: ref, scale: 1)
                    .resizable()
                    .frame(width: fullW, height: fullH)
                    .offset(x: -ox * fullW, y: -oy * fullH)
                Rectangle()
                    .stroke(nav.outside ? Color.orange : Color.yellow, lineWidth: 1.5)
                    .frame(width: max(6, r.width * fullW), height: max(6, r.height * fullH))
                    .offset(x: (r.minX - ox) * fullW, y: (r.minY - oy) * fullH)
            }
            .frame(width: W, height: H, alignment: .topLeading)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.45), lineWidth: 1))
            .shadow(radius: 3)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// v0.39: roda zoom ala kamera bawaan - muncul menggantikan tombol zoom saat tombol ditahan lalu digeser.
/// Skala logaritmik: tiap `ptsPerStop` titik = 2x zoom; geser ke kiri = zoom masuk.
struct ZoomDial: View {
    static let ptsPerStop = 70.0
    let zoom: Double
    let minZ: Double
    let maxZ: Double
    let marks: [Double]

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            func x(_ z: Double) -> CGFloat { cx + CGFloat((log2(z) - log2(max(zoom, 0.01))) * Self.ptsPerStop) }
            var l = (log2(max(minZ, 0.01)) * 5).rounded(.up) / 5
            let top = log2(max(maxZ, minZ))
            while l <= top + 0.001 {
                let px = x(pow(2, l))
                if px >= 0 && px <= size.width {
                    let major = abs(l - l.rounded()) < 0.01
                    var p = Path()
                    p.move(to: CGPoint(x: px, y: size.height - (major ? 14 : 8)))
                    p.addLine(to: CGPoint(x: px, y: size.height - 3))
                    ctx.stroke(p, with: .color(.white.opacity(major ? 0.8 : 0.4)), lineWidth: 1)
                }
                l += 0.2
            }
            for m in marks where m >= minZ - 0.01 && m <= maxZ + 0.01 {
                let px = x(m)
                guard px > 10 && px < size.width - 10 else { continue }
                let t = m < 1 ? String(format: ".%.0f", m * 10) : (abs(m - m.rounded()) < 0.05 ? String(format: "%.0f", m) : String(format: "%.1f", m))
                ctx.draw(Text(t).font(.caption2.bold()).foregroundStyle(.white.opacity(0.85)), at: CGPoint(x: px, y: 9))
            }
            var c = Path()
            c.move(to: CGPoint(x: cx, y: 2))
            c.addLine(to: CGPoint(x: cx, y: size.height - 2))
            ctx.stroke(c, with: .color(.yellow), lineWidth: 2)
        }
        .frame(height: 34)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.yellow.opacity(0.6), lineWidth: 1))
        .overlay(alignment: .top) {
            Text(zoom < 10 ? String(format: "%.1fx", zoom) : String(format: "%.0fx", zoom))
                .font(.caption.bold().monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.yellow, in: Capsule())
                .foregroundStyle(.black)
                .offset(y: -20)
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}
