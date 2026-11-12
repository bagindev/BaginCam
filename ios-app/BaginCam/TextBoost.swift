import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// "Fokus tulisan" untuk AI Zoom: area bertulisan dideteksi (Vision, di HP) lalu memakai AI lebih kuat,
/// area lain tetap campuran biasa supaya daun/kulit tidak seperti lukisan.
enum TextBoost {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// kotak teks dalam koordinat Vision ternormalisasi (0..1, origin kiri-bawah)
    static func textBoxes(in image: CGImage) -> [CGRect] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.01
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch {
            Log.sr.error("Deteksi teks gagal: \(String(describing: error), privacy: .public)")
            return []
        }
        return (req.results ?? []).filter { $0.confidence > 0.2 }.map { $0.boundingBox }
    }

    /// gabungkan: di luar teks = plain/AI dengan `strength`, di dalam kotak teks = `textStrength`
    static func compose(plain: CGImage, ai: CGImage, strength: Double, textStrength: Double,
                        boxes: [CGRect]) -> CGImage? {
        let a = CIImage(cgImage: plain), b = CIImage(cgImage: ai)
        let ext = a.extent
        func mix(_ t: Double) -> CIImage {
            let f = CIFilter.dissolveTransition()
            f.inputImage = a
            f.targetImage = b
            f.time = Float(max(0, min(1, t)))
            return (f.outputImage ?? b).cropped(to: ext)
        }
        let base = mix(strength)
        guard !boxes.isEmpty else { return context.createCGImage(base, from: ext, format: .RGBA8, colorSpace: plain.colorSpace) }
        // masker: putih di kotak teks (diperluas), tepi dihaluskan
        var mask = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: ext)
        for r in boxes {
            let px = CGRect(x: r.minX * ext.width, y: r.minY * ext.height, width: r.width * ext.width, height: r.height * ext.height)
                .insetBy(dx: -r.height * ext.height * 0.35, dy: -r.height * ext.height * 0.35)
                .intersection(ext)
            guard !px.isEmpty else { continue }
            mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: px).composited(over: mask)
        }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = mask.clampedToExtent()
        blur.radius = Float(max(4, ext.width / 300))
        let soft = (blur.outputImage ?? mask).cropped(to: ext)
        let bm = CIFilter.blendWithMask()
        bm.inputImage = mix(textStrength)
        bm.backgroundImage = base
        bm.maskImage = soft
        guard let out = bm.outputImage?.cropped(to: ext) else { return nil }
        return context.createCGImage(out, from: ext, format: .RGBA8, colorSpace: plain.colorSpace)
    }
}
