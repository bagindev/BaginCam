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

    /// keyakinan OCR rata-rata (berbobot panjang teks) untuk satu area
    private static func ocrScore(_ image: CGImage, _ rect: CGRect) -> Float {
        guard let crop = image.cropping(to: rect) else { return 0 }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true      // kata nyata dapat skor lebih tinggi dari huruf karangan
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        guard (try? handler.perform([req])) != nil else { return 0 }
        var sum: Float = 0, n: Float = 0
        for obs in req.results ?? [] {
            guard let top = obs.topCandidates(1).first else { continue }
            let len = Float(max(1, top.string.count))
            sum += top.confidence * len
            n += len
        }
        return n > 0 ? sum / n : 0
    }

    /// pilih per area: AI atau versi asli, menurut OCR
    static func decide(plain: CGImage, ai: CGImage, boxes: [CGRect]) -> [Decision] {
        let W = CGFloat(ai.width), H = CGFloat(ai.height)
        return boxes.map { b in
            // Vision (kiri-bawah) -> piksel (kiri-atas), diperluas sedikit
            var r = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
            r = r.insetBy(dx: -r.height * 0.3, dy: -r.height * 0.3).intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
            let ca = ocrScore(ai, r), cp = ocrScore(plain, r)
            return Decision(box: b, useAI: ca > cp + 0.03, confAI: ca, confPlain: cp)
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
