import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Format simpan hasil HDR+.
enum PhotoFormat: String, CaseIterable, Identifiable {
    case heif = "HEIF"
    case jpeg = "JPEG"
    case dng = "DNG"
    case dngHeif = "DNG+HEIF"
    var id: String { rawValue }
    var wantsDNG: Bool { self == .dng || self == .dngHeif }
    var wantsHEIF: Bool { self == .heif || self == .dngHeif }
    var wantsJPEG: Bool { self == .jpeg }
}

/// Rasio foto (sisi panjang : sisi pendek). Sensor 4:3; 16:9 memotong sisi pendek, 1:1 memotong sisi panjang.
/// Hanya untuk HEIF/JPEG (RAW tetap 4:3).
enum AspectRatio: String, CaseIterable, Identifiable {
    case r43 = "4:3"
    case r169 = "16:9"
    case r11 = "1:1"
    var id: String { rawValue }
    var longOverShort: CGFloat {
        switch self {
        case .r43: return 4.0 / 3.0
        case .r169: return 16.0 / 9.0
        case .r11: return 1
        }
    }
    /// area tengah dengan rasio ini di dalam `r` (orientasi apa pun)
    func rect(in r: CGRect) -> CGRect {
        let landscape = r.width >= r.height
        var long = landscape ? r.width : r.height, short = landscape ? r.height : r.width
        let k = longOverShort
        if long / short < k { short = (long / k).rounded(.down) } else { long = (short * k).rounded(.down) }
        let w = landscape ? long : short, h = landscape ? short : long
        return CGRect(x: (r.minX + (r.width - w) / 2).rounded(.down), y: (r.minY + (r.height - h) / 2).rounded(.down),
                      width: w, height: h)
    }
}

/// "Cuci" DNG jadi foto jadi (HEIF/JPEG) dengan mesin RAW Apple (CIRAWFilter),
/// opsional LUT dibakar ke foto. Dipanggil di processQueue.
enum RawDeveloper {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// DNG -> CIImage tegak (orientasi sudah diterapkan). NR Apple dikurangi karena noise
    /// sudah turun lewat HDR+ merge (NR penuh membuat detail lembek).
    /// `highlight`: persentil 99.9 data RAW ternormalisasi (0..1 = black..white). Bila diberikan,
    /// eksposur diturunkan supaya highlight tidak terpotong (DNG Apple membawa BaselineExposure +0.5..+1 EV
    /// yang diterapkan global -> v0.7.0 langit/kain putih total padahal RAW tidak terpotong), lalu tone map
    /// lokal Apple mengangkat bayangan (mirip Smart HDR).
    /// `metering`: lebar area tengah (fraksi) untuk mengukur kecerahan, mis. 1/crop untuk zoom
    static func develop(dng: Data, highlight: Double? = nil, metering: Double = 1, night: Bool = false,
                        tuning: PhotoTuning = PhotoTuning()) -> CIImage? {
        guard let f = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else {
            Log.hdr.error("CIRAWFilter tidak bisa membuka DNG")
            return nil
        }
        if let hl = highlight, hl > 0.001 {
            // gain total 2^(baseline + exposure): taruh p99.9 di 0.9
            let ev = log2(0.9 / hl) - Double(f.baselineExposure)
            f.exposure = Float(max(-3, min(0, ev)))
        }
        // v0.14: NR luma/warna, ketajaman, detail, HDR lokal, EV tambahan dari Tuning (bawaan = nilai lama)
        tuning.applyRAW(f)
        // kecerahan: develop kecil dulu, ukur rata-rata (linear); bila jauh di atas foto Apple
        // (~0.42 gamma = 0.17 linear) turunkan eksposur (v0.9.1: MF 139 vs Apple 108)
        let fullScale = f.scaleFactor
        f.scaleFactor = 0.125
        if let small = f.outputImage {
            let avg = CIFilter.areaAverage()
            avg.inputImage = small
            let e = small.extent, m = CGFloat(max(0.05, min(1, metering)))
            avg.extent = CGRect(x: e.midX - e.width * m / 2, y: e.midY - e.height * m / 2,
                                width: e.width * m, height: e.height * m)
            if let px = avg.outputImage {
                var v = [Float](repeating: 0, count: 4)
                context.render(px, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf, colorSpace: nil)
                let lum = Double(0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2])
                var adj = 0.0
                if lum > 0.30 { adj = max(-1.2, log2(0.26 / lum)) }
                // MALAM: adegan gelap dicerahkan seperti Night Sight (v0.10.0 maks +1 EV masih terlalu gelap:
                // ruang tanpa lampu linear 0.027 -> sekarang target 0.16, maks +3 EV)
                if night && lum < 0.15 { adj = min(3.0, log2(0.16 / max(lum, 0.003))) }
                // wajah diprioritaskan (v0.9.5: selfie berlatar AC/plafon terang -> diturunkan -1.07 EV,
                // wajah linear 0.15 vs foto Apple 0.28)
                if metering >= 0.99, let face = faceLuminance(small) {
                    adj = max(-1.2, min(0.8, log2(0.24 / face)))
                    Log.hdr.info("Kecerahan wajah: linear \(face, privacy: .public) -> eksposur \(adj, privacy: .public) EV")
                }
                if adj != 0 {
                    f.exposure += Float(adj)
                    Log.hdr.info("Kecerahan: rata-rata linear \(lum, privacy: .public) -> eksposur \(adj, privacy: .public) EV")
                }
            }
        }
        f.scaleFactor = fullScale
        Log.hdr.info("Develop: baseline \(f.baselineExposure, privacy: .public) EV, exposure \(f.exposure, privacy: .public) EV, highlight p99.9 \(highlight ?? -1, privacy: .public)")
        guard let img = f.outputImage else { return nil }
        // piksel sudah tegak -> orientasi metadata harus 1 supaya tidak diputar dua kali
        return img.settingProperties(uprightProperties(img.properties))
    }

    /// luminans linear rata-rata bagian tengah wajah terbesar (nil bila tidak ada wajah)
    private static func faceLuminance(_ small: CIImage) -> Double? {
        let e = small.extent
        guard let cg = context.createCGImage(small, from: e) else { return nil }
        let req = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil,
              let face = (req.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              face.boundingBox.width > 0.08 else { return nil }
        let b = face.boundingBox
        // tengah wajah saja (tanpa rambut/latar)
        let r = CGRect(x: e.minX + (b.minX + b.width * 0.2) * e.width, y: e.minY + (b.minY + b.height * 0.15) * e.height,
                       width: b.width * 0.6 * e.width, height: b.height * 0.6 * e.height).intersection(e)
        guard !r.isEmpty else { return nil }
        let avg = CIFilter.areaAverage()
        avg.inputImage = small
        avg.extent = r
        guard let px = avg.outputImage else { return nil }
        var v = [Float](repeating: 0, count: 4)
        context.render(px, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        let l = Double(0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2])
        return l > 0.005 ? l : nil
    }

    static func uprightProperties(_ p: [String: Any]) -> [String: Any] {
        var props = p
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        props.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        return props
    }

    static func applyLUT(_ image: CIImage, _ lut: CubeLUT?) -> CIImage {
        guard let lut else { return image }
        let f = lut.makeFilter()
        f.setValue(image, forKey: kCIInputImageKey)
        guard let out = f.outputImage else { return image }
        return out.settingProperties(image.properties)
    }

    static func encodeHEIF(_ image: CIImage, quality: Double = 0.92) -> Data? {
        context.heifRepresentation(of: image, format: .RGBA8, colorSpace: p3,
                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }

    static func encodeJPEG(_ image: CIImage, quality: Double = 0.92) -> Data? {
        context.jpegRepresentation(of: image, colorSpace: p3,
                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }

    /// Proses ulang HEIC/JPEG yang sudah jadi: perkecil ke `longSide` (mis. 48MP -> 24MP) dan/atau
    /// bakar LUT. Orientasi tetap di metadata (piksel tidak diputar). nil = tidak perlu / gagal.
    static func reprocess(_ encoded: Data, longSide: Int?, lut: CubeLUT?, aspect: AspectRatio = .r43) -> Data? {
        guard longSide != nil || lut != nil || aspect != .r43,
              let src = CIImage(data: encoded, options: [.applyOrientationProperty: false]) else { return nil }
        var img = src
        if aspect != .r43 {
            img = img.cropped(to: aspect.rect(in: img.extent)).settingProperties(src.properties)
        }
        if let longSide {
            let k = Double(longSide) / Double(max(img.extent.width, img.extent.height))
            if k < 0.999 {
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = img
                f.scale = Float(k)
                f.aspectRatio = 1
                if let o = f.outputImage { img = o.settingProperties(src.properties) }
            }
        }
        img = applyLUT(img, lut)
        return encodeHEIF(img)
    }

    /// CIImage -> CGImage (Display P3, 8 bit).
    static func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: p3)
    }

    /// Campur hasil AI dengan pembesaran biasa: strength 0 = biasa, 1 = AI penuh.
    static func blend(plain: CGImage, ai: CGImage, strength: Double) -> CGImage? {
        if strength >= 0.999 { return ai }
        let a = CIImage(cgImage: plain), b = CIImage(cgImage: ai)
        let f = CIFilter.dissolveTransition()
        f.inputImage = a
        f.targetImage = b
        f.time = Float(max(0, min(1, strength)))
        guard let out = f.outputImage?.cropped(to: a.extent) else { return nil }
        return context.createCGImage(out, from: a.extent, format: .RGBA8,
                                     colorSpace: plain.colorSpace ?? p3)
    }

    /// CGImage -> CIImage -> LUT -> CGImage (untuk AI Zoom).
    static func applyLUT(to cg: CGImage, _ lut: CubeLUT) -> CGImage? {
        let img = applyLUT(CIImage(cgImage: cg), lut)
        return context.createCGImage(img, from: img.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
