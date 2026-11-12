import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// "Fokus tulisan" untuk AI Zoom, berbasis OCR:
/// area bertulisan dideteksi (Vision, di HP), lalu PER AREA dipilih versi yang paling terbaca menurut OCR:
/// versi AI (dikuatkan) atau versi tanpa AI (multi-frame / Lanczos). Uji v0.9.2: AI Detail (x4plus) dengan
/// kekuatan penuh mengarang huruf palsu pada tulisan kecil ("ung beam ul uunubon") -> keyakinan OCR-nya
/// rendah sehingga versi asli yang dipakai.
enum TextBoost {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    struct Decision {
        let box: CGRect        // koordinat Vision ternormalisasi (0..1, origin kiri-bawah)
        let useAI: Bool
        let confAI: Float
        let confPlain: Float
        let sim: Float         // kemiripan teks OCR AI vs asli
    }

    /// kotak teks dalam koordinat Vision ternormalisasi
    static func textBoxes(in image: CGImage) -> [CGRect] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch {
            Log.sr.error("Deteksi teks gagal: \(String(describing: error), privacy: .public)")
            return []
        }
        // kotak terbesar dulu, maksimal 24 (batasi waktu OCR)
        return (req.results ?? []).map { $0.boundingBox }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(24).map { $0 }
    }

    /// gabung kotak teks dari versi AI dan versi asli: tulisan yang dikarang AI sering tidak terdeteksi
    /// sebagai teks di versi AI (v0.9.3: paragraf "Thoso ic on Duiiac" lolos dengan campuran 50%)
    static func mergedBoxes(ai: CGImage, plain: CGImage) -> [CGRect] {
        var out = textBoxes(in: ai)
        for p in textBoxes(in: plain) {
            let covered = out.contains { b in
                let i = b.intersection(p)
                return !i.isNull && i.width * i.height > 0.5 * p.width * p.height
            }
            if !covered { out.append(p) }
        }
        return Array(out.prefix(32))
    }

    /// keyakinan OCR rata-rata (berbobot panjang teks) + teks terbaca untuk satu area
    private static func ocr(_ image: CGImage, _ rect: CGRect) -> (conf: Float, text: String) {
        guard let crop = image.cropping(to: rect) else { return (0, "") }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true      // kata nyata dapat skor lebih tinggi dari huruf karangan
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        guard (try? handler.perform([req])) != nil else { return (0, "") }
        var sum: Float = 0, n: Float = 0, text = ""
        for obs in req.results ?? [] {
            guard let top = obs.topCandidates(1).first else { continue }
            let len = Float(max(1, top.string.count))
            sum += top.confidence * len
            n += len
            text += top.string + " "
        }
        return (n > 0 ? sum / n : 0, text)
    }

    /// kemiripan dua teks OCR (0..1), huruf & angka saja, tanpa beda besar/kecil
    static func similarity(_ a: String, _ b: String) -> Float {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Float(prev[y.count]) / Float(max(x.count, y.count))
    }

    /// pilih per area: AI hanya bila OCR-nya lebih yakin DAN isinya sama dengan yang terbaca dari versi asli.
    /// v0.9.3: keyakinan saja tidak cukup - huruf karangan Detail ("tho bypomlary muvoro") tetap menang.
    static func decide(plain: CGImage, ai: CGImage, boxes: [CGRect]) -> [Decision] {
        let W = CGFloat(ai.width), H = CGFloat(ai.height)
        return boxes.map { b in
            // Vision (kiri-bawah) -> piksel (kiri-atas), diperluas sedikit
            var r = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
            r = r.insetBy(dx: -r.height * 0.3, dy: -r.height * 0.3).intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
            let a = ocr(ai, r), p = ocr(plain, r)
            let sim = similarity(a.text, p.text)
            return Decision(box: b, useAI: a.conf > p.conf + 0.03 && sim >= 0.75,
                            confAI: a.conf, confPlain: p.conf, sim: sim)
        }
    }

    /// gabung: dasar = campuran plain/AI (`strength`); area teks pemenang AI = `textStrength`,
    /// area teks pemenang asli = versi asli murni.
    static func compose(plain: CGImage, ai: CGImage, strength: Double, textStrength: Double,
                        decisions: [Decision]) -> CGImage? {
        let a = CIImage(cgImage: plain), b = CIImage(cgImage: ai)
        let ext = a.extent
        func mix(_ t: Double) -> CIImage {
            let f = CIFilter.dissolveTransition()
            f.inputImage = a
            f.targetImage = b
            f.time = Float(max(0, min(1, t)))
            return (f.outputImage ?? b).cropped(to: ext)
        }
        func mask(_ list: [Decision]) -> CIImage? {
            guard !list.isEmpty else { return nil }
            var m = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: ext)
            for d in list {
                let r = d.box
                let px = CGRect(x: r.minX * ext.width, y: r.minY * ext.height, width: r.width * ext.width, height: r.height * ext.height)
                    .insetBy(dx: -r.height * ext.height * 0.35, dy: -r.height * ext.height * 0.35)
                    .intersection(ext)
                guard !px.isEmpty else { continue }
                m = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: px).composited(over: m)
            }
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = m.clampedToExtent()
            blur.radius = Float(max(4, ext.width / 300))
            return (blur.outputImage ?? m).cropped(to: ext)
        }
        func blend(_ top: CIImage, over bg: CIImage, _ m: CIImage?) -> CIImage {
            guard let m else { return bg }
            let f = CIFilter.blendWithMask()
            f.inputImage = top
            f.backgroundImage = bg
            f.maskImage = m
            return f.outputImage?.cropped(to: ext) ?? bg
        }
        var out = mix(strength)
        out = blend(mix(textStrength), over: out, mask(decisions.filter { $0.useAI }))
        out = blend(a, over: out, mask(decisions.filter { !$0.useAI }))
        return context.createCGImage(out, from: ext, format: .RGBA8, colorSpace: plain.colorSpace)
    }
}
