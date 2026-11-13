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
    kernel vec4 tone48(__sample a, __sample lowA, __sample lowH, __sample h, vec3 gg, float t) {
        vec3 w = vec3(0.2126, 0.7152, 0.0722);
        vec3 la = max(lowA.rgb, vec3(0.002));
        vec3 lh = max(lowH.rgb, vec3(0.002));
        vec3 r = clamp(lh / la, vec3(0.25), vec3(4.0));
        float d = abs(log(dot(lh, w)) - log(max(dot(la * gg, w), 0.002)));
        float m = smoothstep(t, 2.0 * t, d);
        vec3 rr = mix(r, gg, m);
        // area putih terbakar LUAS di foto 48MP (langit, lampu): detail highlight hanya ada di HDR+.
        // v0.18.2: diukur dari lowpass - teks / garis putih kecil tidak lagi diganti HDR+ (pinggiran menyala, IMG_7010)
        float c = smoothstep(0.80, 0.97, max(lowA.r, max(lowA.g, lowA.b)));
        return vec4(mix(a.rgb * rr, h.rgb, c), 1.0);
    }
    """)

    struct Result {
        let image: CIImage
        let note: String
    }

    /// `hdr` dan foto Apple sama-sama sudah tegak. Ukuran keluaran = sisi panjang `targetLong`.
    static func fuse(hdr h0: CIImage, appleData: Data, targetLong: Int, strength: Double = 1) -> Result? {
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
        guard let out = toneK.apply(extent: rect, arguments: [at, lowA, lowH, hAligned, gg, 0.45]) else { return nil }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let note = String(format: "fusi 48MP (geser %.0f,%.0f px)", Double(al.dx), Double(al.dy))
        Log.hdr.info("Fusi 48MP: \(Int(W), privacy: .public)x\(Int(H), privacy: .public), dasar foto48 + tone HDR+ sigma \(sigma, format: .fixed(precision: 1), privacy: .public), geser HDR+ \(Double(al.dx), format: .fixed(precision: 1), privacy: .public),\(Double(al.dy), format: .fixed(precision: 1), privacy: .public) px (\(al.how, privacy: .public)), rasio global \(Double(gg.x), format: .fixed(precision: 2), privacy: .public)/\(Double(gg.y), format: .fixed(precision: 2), privacy: .public)/\(Double(gg.z), format: .fixed(precision: 2), privacy: .public), \(dt, format: .fixed(precision: 2), privacy: .public) s")
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
    private static func align(_ h: CIImage, _ a: CIImage, rect: CGRect) -> (dx: CGFloat, dy: CGFloat, how: String) {
        let s: CGFloat = 1024 / max(rect.width, rect.height)
        let sw = Int((rect.width * s).rounded(.down)), sh = Int((rect.height * s).rounded(.down))
        let sr = CGRect(x: 0, y: 0, width: sw, height: sh)
        let hs = h.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: sr)
        let asm = a.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: sr)
        guard let hcg = ctx.createCGImage(hs, from: sr, format: .RGBA8, colorSpace: sRGB),
              let acg = ctx.createCGImage(asm, from: sr, format: .RGBA8, colorSpace: sRGB) else { return (0, 0, "render gagal") }
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
        let how = String(format: "%@ skor %.3f, vision %.1f,%.1f", best.name, best.score, Double(t.tx), Double(t.ty))
        return (best.dx / s, best.dy / s, how)
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
