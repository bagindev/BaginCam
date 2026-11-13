import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// v0.18: Fusi HDR+ 48MP - warna, HDR & noise dari HDR+ BaginCam (RAW 12MP, 15 frame),
/// detail halus dari 1 foto Apple 48MP (sensor penuh) yang diambil tepat setelah burst.
/// out = lowpass(HDR+) x (luma48 / lowpass(luma48))   -> detail relatif (rasio) dari 48MP,
/// area yang bergerak / tidak cocok (masker hantu) kembali ke HDR+ murni.
enum Fusion48 {
    private static let ctx = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// detail: rasio luma 48MP / lowpass, dikalikan ke lowpass HDR+; m = masker hantu (1 = pakai HDR+)
    private static let fuseKernel = CIColorKernel(source: """
    kernel vec4 fuse48(__sample h, __sample lowH, __sample a, __sample lowA, __sample m, float s) {
        vec3 w = vec3(0.2126, 0.7152, 0.0722);
        float la = dot(a.rgb, w);
        float lla = dot(lowA.rgb, w);
        float r = clamp(la / max(lla, 0.002), 0.4, 2.5);
        r = 1.0 + s * (r - 1.0);
        vec3 f = lowH.rgb * r;
        return vec4(mix(f, h.rgb, clamp(m.r, 0.0, 1.0)), h.a);
    }
    """)

    /// beda kecerahan lokal (log) antara HDR+ dan 48MP (sudah disamakan rata-ratanya) -> 0 cocok .. 1 beda
    private static let ghostKernel = CIColorKernel(source: """
    kernel vec4 ghost48(__sample h, __sample a, float g, float t) {
        vec3 w = vec3(0.2126, 0.7152, 0.0722);
        float lh = max(dot(h.rgb, w), 0.003);
        float la = max(dot(a.rgb, w) * g, 0.003);
        float d = abs(log(lh) - log(la));
        float m = smoothstep(t, 2.0 * t, d);
        return vec4(m, m, m, 1.0);
    }
    """)

    struct Result {
        let image: CIImage
        let note: String
    }

    /// `hdr` dan foto Apple sama-sama sudah tegak. Ukuran keluaran = sisi panjang `targetLong`.
    static func fuse(hdr h0: CIImage, appleData: Data, targetLong: Int, strength: Double = 1) -> Result? {
        guard let fuseK = fuseKernel, let ghostK = ghostKernel else {
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
        var at = resize(a, to: rect.size)

        // 1. sejajarkan (HP bergeser sedikit antara burst dan foto 48MP)
        let al = align(ht, at, rect: rect)
        if al.dx != 0 || al.dy != 0 {
            at = at.transformed(by: CGAffineTransform(translationX: al.dx, y: al.dy)).clampedToExtent().cropped(to: rect)
        }

        // 2. samakan kecerahan rata-rata (tone map Apple beda) untuk masker hantu
        let g = CGFloat(mean(ht) / max(mean(at), 0.0005))

        // 3. lowpass: sigma ~2.5 px di 24MP (frekuensi yang tidak dimiliki data 12MP)
        let sigma = max(1.2, 2.5 * Double(max(W, H)) / 5712)
        let lowH = blur(ht, sigma, rect), lowA = blur(at, sigma, rect)

        // 4. masker hantu di skala kasar (gerak / salah sejajar / beda tone besar), dihaluskan
        let lowH4 = blur(ht, sigma * 4, rect), lowA4 = blur(at, sigma * 4, rect)
        var mask = ghostK.apply(extent: rect, arguments: [lowH4, lowA4, g, 0.22]) ?? CIImage(color: .black).cropped(to: rect)
        mask = blur(mask, sigma * 3, rect)
        let cover = mean(mask)

        guard let out = fuseK.apply(extent: rect, arguments: [ht, lowH, at, lowA, mask, strength]) else { return nil }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let note = String(format: "fusi 48MP (geser %.0f,%.0f px, hantu %.0f%%)", Double(al.dx), Double(al.dy), cover * 100)
        Log.hdr.info("Fusi 48MP: \(Int(W), privacy: .public)x\(Int(H), privacy: .public), sigma \(sigma, format: .fixed(precision: 2), privacy: .public), geser \(Double(al.dx), format: .fixed(precision: 1), privacy: .public),\(Double(al.dy), format: .fixed(precision: 1), privacy: .public) px (\(al.how, privacy: .public)), gain \(Double(g), format: .fixed(precision: 2), privacy: .public), hantu \(cover * 100, format: .fixed(precision: 1), privacy: .public)%, \(dt, format: .fixed(precision: 2), privacy: .public) s (graf)")
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
