import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// v0.18: Fusi HDR+ 48MP - detail dari 1 foto Apple 48MP (sensor penuh) yang diambil tepat setelah burst,
/// warna & tone (HDR, bayangan, kecerahan, tuning) dari HDR+ BaginCam (RAW 12MP, 15 frame).
/// v0.18.1: out = foto48 x clamp(lowpass(HDR+) / lowpass(foto48))  (lowpass kasar ~24 px @24MP).
/// Dulu (v0.18.0) kebalikannya (dasar HDR+ + detail 48MP) -> HP bergeser/berputar sedikit = teks dobel
/// (IMG_7005). Sekarang semua detail & posisi dari satu foto; meleset hanya memengaruhi gradasi kasar.
/// Area yang sangat beda (objek bergerak) memakai rasio rata-rata global.
enum Fusion48 {
    private static let ctx = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// a = foto 48MP, lowA/lowH = lowpass kasar; gg = rasio rata-rata global per kanal; t = ambang beda (log)
    private static let toneKernel = CIColorKernel(source: """
    kernel vec4 tone48(__sample a, __sample lowA, __sample lowH, __sample h, __sample mf, vec3 gg, float t) {
        vec3 w = vec3(0.2126, 0.7152, 0.0722);
        vec3 la = max(lowA.rgb, vec3(0.002));
        vec3 lh = max(lowH.rgb, vec3(0.002));
        vec3 r = clamp(lh / la, vec3(0.25), vec3(4.0));
        float d = abs(log(dot(lh, w)) - log(max(dot(la * gg, w), 0.002)));
        // v0.42.9: + masker gerak (mf.a, struktur beda di 1/4 resolusi); area ditolak memakai rasio tetangga (mf.rgb)
        float m = max(smoothstep(t, 2.0 * t, d), mf.a);
        float hot = smoothstep(0.80, 0.97, max(la.r, max(la.g, la.b)));
        vec3 rr = mix(r, mf.rgb, m * (1.0 - hot));
        // area putih terbakar LUAS di foto 48MP (langit, lampu): detail highlight hanya ada di HDR+.
        // v0.18.2: diukur dari lowpass - teks / garis putih kecil tidak lagi diganti HDR+ (pinggiran menyala, IMG_7010)
        // v0.40.3: hanya bila HDR+ cocok di situ (m kecil) - langit terang dari HDR+ yang meleset = kabel dobel (IMG_7397)
        // v0.42.6: di area terbakar 48MP selisih tidak bisa diukur (48MP putih rata vs HDR+ berawan): ambang
        // "beda" hidup-mati mengikuti awan -> bercak abu-abu berkontur di langit (IMG_7436). Area terbakar kini
        // selalu dari HDR+ (lensa Utama; Ultra Wide tidak difusi sejak v0.40.3, HDR+ yang meleset dibatalkan).
        float clip = smoothstep(0.80, 0.97, max(lowA.r, max(lowA.g, lowA.b)));
        float c = clip * (1.0 - m * (1.0 - clip));
        return vec4(mix(a.rgb * rr, h.rgb, c), 1.0);
    }
    """)

    // v0.42.9: foto 48MP diambil ~0,2 s sebelum burst HDR+ (IMG_7478/7481: motor & orang jadi bayangan tembus
    // pandang, layar biru menempel di kemeja). Masker lama hanya melihat beda kecerahan lowpass (>1,6x) -> objek
    // bergerak dengan kecerahan mirip lolos. Kini struktur lokal dibandingkan (NCC luma log & kroma B/R, jendela
    // ~12 px) di 1/4 resolusi memakai HDR+ asli (bukan lowpass), dilebarkan selebar lowpass.
    private static let fctx = CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    private static let prepKernel = CIColorKernel(source: """
    kernel vec4 gPrep(__sample a, __sample h, float sel) {
        vec3 w = vec3(0.2126, 0.7152, 0.0722);
        float ya = dot(max(a.rgb, vec3(0.0)), w);
        float yh = dot(max(h.rgb, vec3(0.0)), w);
        float la = log(ya + 0.01);
        float lh = log(yh + 0.01);
        float ca = log(max(a.b, 0.0) + 0.01) - log(max(a.r, 0.0) + 0.01);
        float ch = log(max(h.b, 0.0) + 0.01) - log(max(h.r, 0.0) + 0.01);
        vec4 o = vec4(ca * ca, ch * ch, ya, 0.0);
        if (sel < 1.5) { o = vec4(la * lh, ca, ch, ca * ch); }
        if (sel < 0.5) { o = vec4(la, lh, la * la, lh * lh); }
        return o;
    }
    """)
    private static let nccKernel = CIColorKernel(source: """
    kernel vec4 gNcc(__sample p1, __sample p2, __sample p3) {
        float e = 0.0025;
        float vA = max(p1.z - p1.x * p1.x, 0.0);
        float vH = max(p1.w - p1.y * p1.y, 0.0);
        float nl = (p2.x - p1.x * p1.y) / sqrt((vA + e) * (vH + e));
        float ml = (1.0 - smoothstep(0.25, 0.55, nl)) * smoothstep(0.05, 0.12, sqrt(max(vA, vH)));
        float cA = max(p3.x - p2.y * p2.y, 0.0);
        float cH = max(p3.y - p2.z * p2.z, 0.0);
        float nc = (p2.w - p2.y * p2.z) / sqrt((cA + e) * (cH + e));
        float mc = (1.0 - smoothstep(0.25, 0.55, nc)) * smoothstep(0.05, 0.12, sqrt(max(cA, cH))) * smoothstep(0.01, 0.04, p3.z);
        float m = max(ml, mc);
        return vec4(m, m, m, 1.0);
    }
    """)
    /// rasio lowpass dikali bobot "cocok" (premultiplied) untuk konvolusi ternormalisasi
    private static let okKernel = CIColorKernel(source: """
    kernel vec4 gOk(__sample lowA, __sample lowH, __sample m) {
        vec3 r = clamp(max(lowH.rgb, vec3(0.002)) / max(lowA.rgb, vec3(0.002)), vec3(0.25), vec3(4.0));
        float ok = 1.0 - clamp(m.r, 0.0, 1.0);
        return vec4(r * ok, ok);
    }
    """)
    private static let fillKernel = CIColorKernel(source: """
    kernel vec4 gFill(__sample b, __sample m, vec3 gg) {
        vec3 f = b.rgb / max(b.a, 0.001);
        return vec4(mix(gg, f, smoothstep(0.02, 0.10, b.a)), clamp(m.r, 0.0, 1.0));
    }
    """)
    private static let overlayKernel = CIColorKernel(source: """
    kernel vec4 gOver(__sample a, __sample m) {
        return vec4(mix(a.rgb, vec3(1.0, 0.0, 0.0), 0.65 * clamp(m.a, 0.0, 1.0)), 1.0);
    }
    """)

    /// masker gerak (alpha) + rasio pengganti dari tetangga yang cocok (rgb), ukuran `rect`; frac = bagian gambar > 0.5
    private static func motionMask(a: CIImage, h: CIImage, lowA: CIImage, lowH: CIImage, gg: CIVector, sigma: Double,
                                   rect: CGRect, debugName: String?) -> (image: CIImage, frac: Double)? {
        guard let prep = prepKernel, let ncc = nccKernel, let okK = okKernel, let fillK = fillKernel else { return nil }
        let w4 = max(16, Int((rect.width / 4).rounded())), h4 = max(16, Int((rect.height / 4).rounded()))
        let r4 = CGRect(x: 0, y: 0, width: w4, height: h4)
        let a4 = resize(a, to: r4.size), hq = resize(h, to: r4.size)
        let la4 = resize(lowA, to: r4.size), lh4 = resize(lowH, to: r4.size)
        func g(_ i: CIImage, _ s: Double) -> CIImage { blur(i, s, r4) }
        var p: [CIImage] = []
        for sel in 0..<3 {
            guard let o = prep.apply(extent: r4, arguments: [a4, hq, Double(sel)]) else { return nil }
            p.append(g(o, 3))
        }
        guard let m0 = ncc.apply(extent: r4, arguments: p) else { return nil }
        // dilebarkan selebar jangkauan lowpass (bayangan menyebar ~2 sigma)
        let dil = CIFilter.morphologyMaximum()
        dil.inputImage = m0.clampedToExtent()
        dil.radius = Float(max(2, sigma / 4 * 1.5))
        let m1 = g((dil.outputImage ?? m0).cropped(to: r4), max(1, sigma / 8))
        guard let pre = okK.apply(extent: r4, arguments: [la4, lh4, m1]) else { return nil }
        guard let mf = fillK.apply(extent: r4, arguments: [g(pre, sigma), m1, gg]) else { return nil }
        var buf = [Float](repeating: 0, count: w4 * h4 * 4)
        fctx.render(mf, toBitmap: &buf, rowBytes: w4 * 16, bounds: r4, format: .RGBAf, colorSpace: nil)
        var n = 0
        for i in stride(from: 3, to: buf.count, by: 4) where buf[i] > 0.5 { n += 1 }
        let data = buf.withUnsafeBufferPointer { Data(buffer: $0) }
        let small = CIImage(bitmapData: data, bytesPerRow: w4 * 16, size: CGSize(width: w4, height: h4), format: .RGBAf, colorSpace: nil)
        if let debugName, let ov = overlayKernel?.apply(extent: r4, arguments: [a4, small]),
           let jpg = ctx.jpegRepresentation(of: ov, colorSpace: sRGB, options: [:]) {
            CameraManager.saveDebug(jpg, name: debugName)
        }
        let up = small.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: rect.width / CGFloat(w4), y: rect.height / CGFloat(h4)))
            .clampedToExtent().cropped(to: rect)
        return (up, Double(n) / Double(w4 * h4))
    }

    struct Result {
        let image: CIImage
        let note: String
    }

    /// `hdr` dan foto Apple sama-sama sudah tegak. Ukuran keluaran = sisi panjang `targetLong`.
    static func fuse(hdr h0: CIImage, appleData: Data, targetLong: Int, strength: Double = 1, debugName: String? = nil) -> Result? {
        guard let toneK = toneKernel else {
            Log.hdr.error("Fusi 48MP: kernel tidak bisa dibuat")
            return nil
        }
        guard let a0 = CIImage(data: appleData, options: [.applyOrientationProperty: true]) else {
            Log.hdr.error("Fusi 48MP: foto 48MP tidak bisa dibaca")
            return nil
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let h = origin(h0), a = origin(a0)
        let rh = h.extent.width / h.extent.height, ra = a.extent.width / a.extent.height
        guard abs(rh - ra) < 0.03 else {
            Log.hdr.error("Fusi 48MP: rasio beda \(Double(rh), privacy: .public) vs \(Double(ra), privacy: .public) (orientasi?)")
            return nil
        }
        let k = CGFloat(targetLong) / max(h.extent.width, h.extent.height)
        let W = (h.extent.width * k).rounded(), H = (h.extent.height * k).rounded()
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        let ht = resize(h, to: rect.size)
        let at = resize(a, to: rect.size)

        // 1. geser HDR+ (bukan foto 48MP) supaya tone jatuh di tempat yang benar
        let al = align(at, ht, rect: rect)
        // v0.18.3: foto 48MP buram (HP bergerak, IMG_7012) -> jangan dipakai, kembali ke HDR+ biasa
        // v0.19: align(at, ht) -> sharpRatio = HDR+/48MP (terbalik; v0.18.3-0.18.5 semua fusi batal, rasio 0.4-0.7
        // padahal 48MP 1.2x lebih tajam - dikalibrasi dari foto debug IMG_7018-7026)
        let sharp48 = al.sharpRatio > 0 ? 1 / al.sharpRatio : 1
        // v0.42.6: HDR+ tidak bisa diselaraskan dengan foto 48MP (HP bergeser jauh: IMG_7436 geser -95,-39 px,
        // skor 0.563 -> bercak / tepi dobel) -> batal, pakai HDR+ biasa. Foto bagus sore itu skor 0.16-0.44.
        if al.score > 0.5 {
            Log.hdr.notice("Fusi 48MP: dibatalkan - HDR+ tidak cocok dengan foto 48MP (skor \(al.score, format: .fixed(precision: 3), privacy: .public), geser \(Double(al.dx), format: .fixed(precision: 0), privacy: .public),\(Double(al.dy), format: .fixed(precision: 0), privacy: .public) px)")
            return nil
        }
        // v0.42.9: geser besar = HP bergerak cepat (IMG_7478 geser 39,184 px skor 0.327 -> layar & orang dobel);
        // translasi saja tidak cukup (putar / paralaks) -> batal. Foto bagus: geser <= ~55 px di 5712.
        let shift = hypot(Double(al.dx), Double(al.dy)), maxShift = 0.015 * Double(max(W, H))
        if shift > maxShift {
            Log.hdr.notice("Fusi 48MP: dibatalkan - HP bergeser \(shift, format: .fixed(precision: 0), privacy: .public) px antara foto 48MP dan HDR+ (batas \(maxShift, format: .fixed(precision: 0), privacy: .public), skor \(al.score, format: .fixed(precision: 3), privacy: .public))")
            return nil
        }
        if sharp48 < 0.85 {
            Log.hdr.notice("Fusi 48MP: dibatalkan - foto 48MP lebih buram dari HDR+ (48/HDR \(sharp48, format: .fixed(precision: 2), privacy: .public), geser \(Double(al.dx), format: .fixed(precision: 0), privacy: .public),\(Double(al.dy), format: .fixed(precision: 0), privacy: .public) px)")
            return nil
        }
        var hAligned = ht
        if al.dx != 0 || al.dy != 0 {
            hAligned = ht.transformed(by: CGAffineTransform(translationX: al.dx, y: al.dy)).clampedToExtent().cropped(to: rect)
        }

        // 2. rasio global per kanal (cadangan untuk area yang sangat beda)
        let mh = meanRGB(hAligned), ma = meanRGB(at)
        let gg = CIVector(x: CGFloat(mh.0 / max(ma.0, 0.0005)), y: CGFloat(mh.1 / max(ma.1, 0.0005)),
                          z: CGFloat(mh.2 / max(ma.2, 0.0005)))

        // 3. lowpass kasar (~24 px @24MP) -> tone & warna HDR+ dipindah ke foto 48MP
        let sigma = max(8, 24 * Double(max(W, H)) / 5712)
        let lowH = blur(hAligned, sigma, rect), lowA = blur(at, sigma, rect)
        let tm = CFAbsoluteTimeGetCurrent()
        guard let mm = motionMask(a: at, h: hAligned, lowA: lowA, lowH: lowH, gg: gg, sigma: sigma, rect: rect,
                                  debugName: debugName.map { $0 + "_gerak.jpg" }) else {
            Log.hdr.error("Fusi 48MP: masker gerak gagal dibuat")
            return nil
        }
        Log.hdr.notice("Fusi 48MP: masker gerak \(mm.frac * 100, format: .fixed(precision: 1), privacy: .public)% gambar, \(CFAbsoluteTimeGetCurrent() - tm, format: .fixed(precision: 2), privacy: .public) s")
        // sebagian besar adegan berubah (banyak orang / kendaraan, HP berputar) -> fusi tidak berguna
        if mm.frac > 0.40 {
            Log.hdr.notice("Fusi 48MP: dibatalkan - \(mm.frac * 100, format: .fixed(precision: 0), privacy: .public)% gambar beda (gerak) antara foto 48MP dan HDR+")
            return nil
        }
        guard let out = toneK.apply(extent: rect, arguments: [at, lowA, lowH, hAligned, mm.image, gg, 0.45]) else { return nil }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let note = String(format: "fusi 48MP (geser %.0f,%.0f px, tajam %.2fx, gerak %.0f%%)", Double(al.dx), Double(al.dy), sharp48, mm.frac * 100)
        Log.hdr.notice("Fusi 48MP: \(Int(W), privacy: .public)x\(Int(H), privacy: .public), dasar foto48 + tone HDR+ sigma \(sigma, format: .fixed(precision: 1), privacy: .public), geser HDR+ \(Double(al.dx), format: .fixed(precision: 1), privacy: .public),\(Double(al.dy), format: .fixed(precision: 1), privacy: .public) px (\(al.how, privacy: .public)), rasio global \(Double(gg.x), format: .fixed(precision: 2), privacy: .public)/\(Double(gg.y), format: .fixed(precision: 2), privacy: .public)/\(Double(gg.z), format: .fixed(precision: 2), privacy: .public), \(dt, format: .fixed(precision: 2), privacy: .public) s")
        return Result(image: out, note: note)
    }

    // MARK: alat bantu

    private static func origin(_ i: CIImage) -> CIImage {
        i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
    }

    private static func resize(_ i: CIImage, to size: CGSize) -> CIImage {
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = i
        f.scale = Float(size.height / i.extent.height)
        f.aspectRatio = Float((size.width / i.extent.width) / (size.height / i.extent.height))
        return (f.outputImage ?? i).cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func blur(_ i: CIImage, _ sigma: Double, _ rect: CGRect) -> CIImage {
        let f = CIFilter.gaussianBlur()
        f.inputImage = i.clampedToExtent()
        f.radius = Float(sigma)
        return (f.outputImage ?? i).cropped(to: rect)
    }

    private static func meanRGB(_ i: CIImage) -> (Double, Double, Double) {
        let f = CIFilter.areaAverage()
        f.inputImage = i
        f.extent = i.extent
        guard let px = f.outputImage else { return (0, 0, 0) }
        var v = [Float](repeating: 0, count: 4)
        ctx.render(px, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (Double(v[0]), Double(v[1]), Double(v[2]))
    }

    private static func mean(_ i: CIImage) -> Double {
        let f = CIFilter.areaAverage()
        f.inputImage = i
        f.extent = i.extent
        guard let px = f.outputImage else { return 0 }
        var v = [Float](repeating: 0, count: 4)
        ctx.render(px, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2])
    }

    /// geser (piksel CI, y ke atas) yang menyejajarkan `a` ke `h`: Vision (translasi) lalu dicek
    /// dengan selisih luma ternormalisasi - pilih kandidat terbaik (termasuk tanpa geser).
    /// sharpRatio = energi tepi a / h (di 1024 px): < 1 = a lebih buram
    private static func align(_ h: CIImage, _ a: CIImage, rect: CGRect) -> (dx: CGFloat, dy: CGFloat, how: String, sharpRatio: Double, score: Double) {
        let s: CGFloat = 1024 / max(rect.width, rect.height)
        let sw = Int((rect.width * s).rounded(.down)), sh = Int((rect.height * s).rounded(.down))
        let sr = CGRect(x: 0, y: 0, width: sw, height: sh)
        let hs = h.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: sr)
        let asm = a.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: sr)
        guard let hcg = ctx.createCGImage(hs, from: sr, format: .RGBA8, colorSpace: sRGB),
              let acg = ctx.createCGImage(asm, from: sr, format: .RGBA8, colorSpace: sRGB) else { return (0, 0, "render gagal", 1, 0) }
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: acg)
        try? VNImageRequestHandler(cgImage: hcg).perform([req])
        let t = (req.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform ?? .identity
        let hv = gray(hs, sw, sh), av = gray(asm, sw, sh)
        var best = (dx: CGFloat(0), dy: CGFloat(0), score: score(hv, av, sw, sh, 0, 0), name: "tanpa")
        for (sx, sy) in [(1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0)] {
            let dx = t.tx * sx, dy = t.ty * sy
            let sc = score(hv, av, sw, sh, Int(dx.rounded()), Int(dy.rounded()))
            if sc < best.score { best = (dx, dy, sc, String(format: "vision %+.0f%+.0f", sx, sy)) }
        }
        let sharp = Double(edge(hv, sw, sh)) > 0 ? Double(edge(av, sw, sh) / edge(hv, sw, sh)) : 1
        let how = String(format: "%@ skor %.3f, vision %.1f,%.1f, energi tepi b/a %.2f", best.name, best.score, Double(t.tx), Double(t.ty), sharp)
        return (best.dx / s, best.dy / s, how, sharp, Double(best.score))
    }

    /// energi tepi rata-rata (luma ternormalisasi) - ukuran ketajaman
    private static func edge(_ v: [Float], _ w: Int, _ h: Int) -> Float {
        var s: Float = 0
        var n = 0
        var y = 1
        while y < h - 1 {
            var x = 1
            while x < w - 1 {
                let p = y * w + x
                s += abs(v[p + 1] - v[p - 1]) + abs(v[p + w] - v[p - w])
                n += 1
                x += 2
            }
            y += 2
        }
        return n > 0 ? s / Float(n) : 0
    }

    /// luma kecil, baris 0 = atas, dinormalisasi (rata-rata 0, simpangan 1)
    private static func gray(_ i: CIImage, _ w: Int, _ h: Int) -> [Float] {
        var buf = [Float](repeating: 0, count: w * h * 4)
        ctx.render(i, toBitmap: &buf, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        var l = [Float](repeating: 0, count: w * h)
        var sum: Float = 0
        for p in 0..<(w * h) {
            let v = 0.2126 * buf[p * 4] + 0.7152 * buf[p * 4 + 1] + 0.0722 * buf[p * 4 + 2]
            l[p] = v; sum += v
        }
        let m = sum / Float(w * h)
        var vs: Float = 0
        for p in 0..<(w * h) { let d = l[p] - m; vs += d * d }
        let sd = max(sqrt(vs / Float(w * h)), 1e-4)
        for p in 0..<(w * h) { l[p] = (l[p] - m) / sd }
        return l
    }

    /// rata-rata |h - a digeser| ; geser CI (dx kanan, dy atas) -> di larik (baris atas) a(x - dx, y + dy)
    private static func score(_ h: [Float], _ a: [Float], _ w: Int, _ hh: Int, _ dx: Int, _ dy: Int) -> Float {
        let m = 16
        var sum: Float = 0
        var n = 0
        var y = m
        while y < hh - m {
            let ay = y + dy
            if ay >= 0 && ay < hh {
                var x = m
                while x < w - m {
                    let ax = x - dx
                    if ax >= 0 && ax < w { sum += abs(h[y * w + x] - a[ay * w + ax]); n += 1 }
                    x += 2
                }
            }
            y += 2
        }
        return n > 0 ? sum / Float(n) : .greatestFiniteMagnitude
    }
}
