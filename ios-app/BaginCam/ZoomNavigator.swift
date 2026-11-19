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
    static let maxBox: CGFloat = 0.6        // kotak > 60 % gambar acuan = peta tidak berguna -> disembunyikan

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
    // v0.42.7: acuan dulu hanya diambil saat zoom < 6x -> pindah 10x / 25x / 40x atau merekam lama di zoom tinggi =
    // peta memakai gambar lama (tempat lain, IMG_7466) sampai zoom out. Sekarang: acuan juga diambil saat zoom kembali
    // ke tingkat acuan / lebih lebar, hanya setelah zoom diam, dan dicocokkan terus dengan preview.
    private var zoomChangedAt = 0.0
    private var lastProbe = 0.0
    private var misses = 0
    private var stale = false               // acuan terbukti tidak cocok dengan preview -> sembunyi, minta acuan baru
    private var refGray: [Float] = []
    private var refW = 0, refH = 0

    /// v0.42.8: acuan hanya dari zoom < 6x (gambar lebar). Build 115 juga mengambil acuan di zoom tinggi (saat basi /
    /// kembali ke tingkat acuan) -> peta 50x berisi tampilan 25x yang sempit (IMG_7468). Preview di zoom tinggi sudah
    /// di-crop kamera, jadi gambar lebar hanya ada saat zoom rendah (kamera bawaan memakai aliran kamera kedua).
    var wantsRef: Bool { enabled && zoom < Self.refBelow }
    /// minta frame preview untuk dicocokkan dengan peta (tiap ~0,5 s selama peta tampil)
    var wantsProbe: Bool { visible && !outside }

    func setZoom(_ z: CGFloat, fovTan1x t: Double) {
        if abs(z - zoom) > 0.001 { zoomChangedAt = CACurrentMediaTime() }
        zoom = z
        if t > 0.01 { fovTan1x = t }
        refresh()
    }

    /// gambar yang sedang tampil di layar (sudah di-crop zoom preview & diperkecil ke ukuran layar)
    func offer(_ image: CIImage, context: CIContext) {
        let now = CACurrentMediaTime()
        // zoom masih bergerak (ramp) -> frame belum sesuai angka zoom
        guard wantsRef, now - lastOffer > 0.4, now - zoomChangedAt > 0.6 else { return }
        lastOffer = now
        let e = image.extent
        guard e.width > 8, e.height > 8 else { return }
        let k = min(1, 360 / e.width)
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = context.createCGImage(small, from: small.extent) else { return }
        ref = cg
        refW = cg.width
        refH = cg.height
        refGray = Self.gray(cg, refW, refH)
        refZoom = zoom
        refTanW = fovTan1x / Double(max(zoom, 0.1))
        refTanH = refTanW * Double(e.height / e.width)
        tiltX = 0
        tiltY = 0
        misses = 0
        if stale { stale = false }
        refresh()
    }

    /// cocokkan preview sekarang dengan potongan peta di posisi kotak (NCC, cari +-8 px): cocok -> posisi kotak
    /// dikoreksi (gyro tidak melenceng); 2x tidak cocok -> acuan basi, peta disembunyikan & acuan baru diminta
    func probe(_ image: CIImage, context: CIContext) {
        let now = CACurrentMediaTime()
        guard wantsProbe, now - lastProbe > 0.5, now - zoomChangedAt > 0.8, refW > 0, refGray.count == refW * refH else { return }
        lastProbe = now
        let tw = Int(rect.width * CGFloat(refW)), th = Int(rect.height * CGFloat(refH))
        guard tw >= 16, th >= 16, tw < refW, th < refH else { return }
        let e = image.extent
        guard e.width > 8, e.height > 8 else { return }
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(tw) / e.width, y: CGFloat(th) / e.height))
        guard let cg = context.createCGImage(small, from: CGRect(x: 0, y: 0, width: tw, height: th)) else { return }
        let t = Self.gray(cg, tw, th)
        guard t.count == tw * th else { return }
        // templat (sampel tiap 2 px), dinormalisasi
        var idx: [Int] = []
        var y = 0
        while y < th { var x = 0; while x < tw { idx.append(y * tw + x); x += 2 }; y += 2 }
        let n = Float(idx.count)
        var tm: Float = 0
        for i in idx { tm += t[i] }
        tm /= n
        var tv: Float = 0
        for i in idx { let d = t[i] - tm; tv += d * d }
        let tsd = sqrt(tv / n)
        guard tsd > 6 else { return }          // adegan polos (langit, dinding): tidak bisa dinilai
        let px0 = Int(rect.minX * CGFloat(refW)), py0 = Int(rect.minY * CGFloat(refH))
        let R = 8
        var best: Float = -1, bx = px0, by = py0
        for dy in stride(from: -R, through: R, by: 1) {
            let oy = py0 + dy
            guard oy >= 0, oy + th <= refH else { continue }
            for dx in stride(from: -R, through: R, by: 1) {
                let ox = px0 + dx
                guard ox >= 0, ox + tw <= refW else { continue }
                var sr: Float = 0, srr: Float = 0, srt: Float = 0
                for i in idx {
                    let ty = i / tw, tx = i - ty * tw
                    let r = refGray[(oy + ty) * refW + ox + tx]
                    sr += r; srr += r * r; srt += r * (t[i] - tm)
                }
                let rm = sr / n
                let rsd = sqrt(max(srr / n - rm * rm, 0))
                guard rsd > 1 else { continue }
                let ncc = srt / n / (rsd * tsd)
                if ncc > best { best = ncc; bx = ox; by = oy }
            }
        }
        // koreksi posisi hanya bila templat cukup besar & sangat cocok
        if tw >= 40 && best >= 0.6 {
            misses = 0
            // pusat kotak dikunci ke posisi yang cocok (koreksi melenceng gyro)
            let cx = (Double(bx) + Double(tw) / 2) / Double(refW), cy = (Double(by) + Double(th) / 2) / Double(refH)
            tiltY = atan((0.5 - cx) * 2 * refTanW)
            tiltX = atan((0.5 - cy) * 2 * refTanH)
            updateRect()
            return
        }
        // v0.42.8: basi dinilai pada grid kasar (12 kolom: tata letak terang / gelap), bukan detail halus. Build 115:
        // kotak 28 px (25x dari acuan 2x) -> detail 25x tidak bisa dibandingkan -> NCC 0.38 padahal tempat sama.
        let gw = 12, gh = max(4, Int((Double(th) / Double(tw) * 12).rounded()))
        func cells(_ get: (Int, Int) -> Float) -> [Float] {
            var c = [Float](repeating: 0, count: gw * gh)
            for gy in 0..<gh {
                let y0 = gy * th / gh, y1 = max(y0 + 1, (gy + 1) * th / gh)
                for gx in 0..<gw {
                    let x0 = gx * tw / gw, x1 = max(x0 + 1, (gx + 1) * tw / gw)
                    var sum: Float = 0
                    for yy in y0..<y1 { for xx in x0..<x1 { sum += get(xx, yy) } }
                    c[gy * gw + gx] = sum / Float((y1 - y0) * (x1 - x0))
                }
            }
            return c
        }
        let ct = cells { x, y in t[y * tw + x] }
        let cr = cells { x, y in self.refGray[(by + y) * self.refW + bx + x] }
        func stat(_ v: [Float]) -> (Float, Float) {
            let m = v.reduce(0, +) / Float(v.count)
            let sd = sqrt(v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(v.count))
            return (m, sd)
        }
        let (mt, st) = stat(ct), (mr, sr) = stat(cr)
        guard st > 8 else { return }           // preview polos: tidak bisa dinilai
        var cc: Float = 0
        if sr > 2 { for i in 0..<ct.count { cc += (ct[i] - mt) * (cr[i] - mr) }; cc /= Float(ct.count) * st * sr }
        if cc >= 0.3 {
            misses = 0
        } else {
            misses += 1
            if misses >= 3 && !stale {
                stale = true
                Log.camera.notice("Peta zoom: acuan tidak cocok lagi dengan preview (grid \(cc, format: .fixed(precision: 2), privacy: .public), detail \(best, format: .fixed(precision: 2), privacy: .public), zoom \(Double(self.zoom), format: .fixed(precision: 1), privacy: .public)x, acuan \(Double(self.refZoom), format: .fixed(precision: 1), privacy: .public)x) - disembunyikan sampai zoom < 6x")
                refresh()
            }
        }
    }

    private static func gray(_ cg: CGImage, _ w: Int, _ h: Int) -> [Float] {
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            c.interpolationQuality = .medium
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px.map { Float($0) } : []
    }

    private func refresh() {
        let f = refZoom / max(zoom, 0.1)
        let show = enabled && zoom >= Self.showAt && ref != nil && !stale && f <= Self.maxBox
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
