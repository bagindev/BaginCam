import CoreImage
import ImageIO
import UniformTypeIdentifiers

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

/// "Cuci" DNG jadi foto jadi (HEIF/JPEG) dengan mesin RAW Apple (CIRAWFilter),
/// opsional LUT dibakar ke foto. Dipanggil di processQueue.
enum RawDeveloper {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// DNG -> CIImage tegak (orientasi sudah diterapkan). NR Apple dikurangi karena noise
    /// sudah turun lewat HDR+ merge (NR penuh membuat detail lembek).
    static func develop(dng: Data, noiseReductionScale: Float = 0.4) -> CIImage? {
        guard let f = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else {
            Log.hdr.error("CIRAWFilter tidak bisa membuka DNG")
            return nil
        }
        if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount *= noiseReductionScale }
        if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount *= max(noiseReductionScale, 0.6) }
        guard let img = f.outputImage else { return nil }
        // piksel sudah tegak -> orientasi metadata harus 1 supaya tidak diputar dua kali
        return img.settingProperties(uprightProperties(img.properties))
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

    /// Bakar LUT ke HEIC/JPEG yang sudah jadi (orientasi tetap di metadata, piksel tidak diputar).
    static func bakeLUT(into encoded: Data, lut: CubeLUT, asJPEG: Bool = false) -> Data? {
        guard let src = CIImage(data: encoded, options: [.applyOrientationProperty: false]) else { return nil }
        let img = applyLUT(src, lut)
        return asJPEG ? encodeJPEG(img) : encodeHEIF(img)
    }

    /// CGImage -> CIImage -> LUT -> CGImage (untuk AI Zoom).
    static func applyLUT(to cg: CGImage, _ lut: CubeLUT) -> CGImage? {
        let img = applyLUT(CIImage(cgImage: cg), lut)
        return context.createCGImage(img, from: img.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
