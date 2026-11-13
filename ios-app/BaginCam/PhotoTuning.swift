import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// v0.19: gaya warna cepat (chip Warna). HDR+ BaginCam ~0.5 EV lebih gelap & lebih dingin dari foto Apple
/// (restoran IMG_6975 vs 6976, Ultra Wide IMG_7021 vs foto 48MP) -> pilihan, bukan paksaan.
enum ColorStyle: String, CaseIterable, Identifiable {
    case natural = "Natural"
    case bright = "Cerah"
    case warm = "Hangat"
    case apple = "Ala Apple"
    case vivid = "Vivid"
    case mono = "Hitam putih"
    var id: String { rawValue }
    /// EV tambahan setelah eksposur otomatis
    var ev: Double { [0, 0.45, 0.15, 0.5, 0.2, 0.1][index] }
    /// + = hangat (merah naik, biru turun)
    var warmth: Double { [0, 0, 0.06, 0.035, 0.015, 0][index] }
    var vibrance: Double { [0, 0.05, 0.1, 0.15, 0.4, 0][index] }
    var contrast: Double { [0, -0.05, 0, 0.1, 0.3, 0.25][index] }
    var detail: String {
        ["warna asli HDR+ BaginCam", "lebih terang, bayangan terbuka", "lebih hangat (makanan, kulit, sore)",
         "terang + hangat + sedikit kontras, mirip kamera iPhone", "warna kuat & kontras", "monokrom kontras"][index]
    }
    private var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    func apply(_ input: CIImage) -> CIImage {
        guard self != .natural else { return input }
        var img = input
        let ext = input.extent
        if warmth != 0 {
            let m = CIFilter.colorMatrix()
            m.inputImage = img
            m.rVector = CIVector(x: CGFloat(1 + warmth), y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: CGFloat(1 + warmth * 0.25), z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: CGFloat(1 - warmth * 1.2), w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            img = m.outputImage ?? img
        }
        var t = PhotoTuning(localTone: 0, sharpness: 1, detail: 1, lumaNR: 1, chromaNR: 1)
        t.contrast = contrast
        t.saturation = vibrance
        img = t.post(img)
        if self == .mono {
            let c = CIFilter.photoEffectMono()
            c.inputImage = img
            img = c.outputImage ?? img
        }
        return img.cropped(to: ext)
    }
}

/// v0.14: tuning proses foto ala AGC (GCam) - dipakai HDR+, Super Res, MALAM, AI Zoom.
/// Bagian RAW masuk ke CIRAWFilter saat develop; bagian "akhir" dijalankan setelah zoom / upscale
/// (penajaman akhir di resolusi output, bayangan/highlight, kontras, saturasi). Tidak berlaku untuk
/// FOTO proses Apple / ProRAW / video.
struct PhotoTuning: Codable, Equatable {
    // develop RAW
    var exposure: Double = 0        // EV tambahan -1..+1
    var localTone: Double = 0.8     // 0..1 HDR lokal Apple (mengangkat bayangan, menahan langit)
    var sharpness: Double = 1       // 0..2 pengali ketajaman RAW Apple
    var detail: Double = 1          // 0..2 pengali detail halus RAW Apple
    var lumaNR: Double = 0.6        // 0..1.5 pengali NR luminans (butiran)
    var chromaNR: Double = 0.8      // 0..1.5 pengali NR warna (bintik warna)
    // akhir
    var shadows: Double = 0         // -1..+1 (+ = bayangan lebih terang)
    var highlights: Double = 0      // 0..1 selamatkan highlight (langit / kulit terang)
    var contrast: Double = 0        // -1..+1
    var saturation: Double = 0      // -1..+1
    var finalSharpen: Double = 0    // 0..1 penajaman akhir (setelah zoom / upscale)
    var finalRadius: Double = 1.5   // 0.5..4 px

    static let key = "photoTuning"

    static func load() -> PhotoTuning {
        guard let d = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode(PhotoTuning.self, from: d) else { return PhotoTuning() }
        return t
    }

    func store() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    var isDefault: Bool { self == PhotoTuning() }

    /// preset cepat
    static let presets: [(String, PhotoTuning)] = [
        ("Natural (bawaan)", PhotoTuning()),
        ("Tajam (detail maksimal)", PhotoTuning(sharpness: 1.5, detail: 1.6, lumaNR: 0.3, chromaNR: 0.7,
                                                finalSharpen: 0.35, finalRadius: 1.2)),
        ("Lembut (noise rendah)", PhotoTuning(sharpness: 0.7, detail: 0.7, lumaNR: 1.1, chromaNR: 1.2)),
        ("Kontras (ala GCam)", PhotoTuning(localTone: 0.6, sharpness: 1.2, detail: 1.2, lumaNR: 0.45,
                                          shadows: -0.15, contrast: 0.35, saturation: 0.15, finalSharpen: 0.15)),
        ("Bayangan terang (HDR)", PhotoTuning(localTone: 1, shadows: 0.45, highlights: 0.4)),
    ]

    /// ringkasan untuk log / status
    var summary: String {
        isDefault ? "natural" : String(format: "EV%+.1f LTM%.1f tajam%.1f detail%.1f NR%.1f/%.1f bayangan%+.1f highlight%.1f kontras%+.1f sat%+.1f akhir%.2f@%.1f",
                                       exposure, localTone, sharpness, detail, lumaNR, chromaNR, shadows, highlights,
                                       contrast, saturation, finalSharpen, finalRadius)
    }

    // MARK: develop RAW

    func applyRAW(_ f: CIRAWFilter) {
        if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount *= Float(lumaNR) }
        if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount *= Float(chromaNR) }
        if f.isSharpnessSupported { f.sharpnessAmount *= Float(sharpness) }
        if f.isDetailSupported { f.detailAmount *= Float(detail) }
        if f.isLocalToneMapSupported { f.localToneMapAmount = Float(localTone) }
        f.exposure += Float(exposure)
    }

    // MARK: akhir (setelah zoom / upscale, sebelum LUT)

    func post(_ input: CIImage) -> CIImage {
        var img = input
        let ext = input.extent
        if abs(shadows) > 0.01 || highlights > 0.01 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.shadowAmount = Float(shadows)
            f.highlightAmount = Float(1 - 0.7 * highlights)
            f.radius = Float(max(ext.width, ext.height) / 300)          // lokal, tidak bergantung resolusi
            img = f.outputImage ?? img
        }
        if abs(contrast) > 0.01 {
            // kurva S di ruang gamma (bukan linear) supaya titik tengah tidak bergeser
            let c = CGFloat(contrast) * 0.07
            let t = CIFilter.toneCurve()
            t.inputImage = img.applyingFilter("CILinearToSRGBToneCurve")
            t.point0 = CGPoint(x: 0, y: 0)
            t.point1 = CGPoint(x: 0.25, y: 0.25 - c)
            t.point2 = CGPoint(x: 0.5, y: 0.5)
            t.point3 = CGPoint(x: 0.75, y: 0.75 + c)
            t.point4 = CGPoint(x: 1, y: 1)
            if let o = t.outputImage { img = o.applyingFilter("CISRGBToneCurveToLinear") }
        }
        if abs(saturation) > 0.01 {
            let v = CIFilter.vibrance()                          // vibrance: kulit tidak berlebihan
            v.inputImage = img
            v.amount = Float(saturation)
            img = v.outputImage ?? img
        }
        if finalSharpen > 0.01 {
            let u = CIFilter.unsharpMask()
            u.inputImage = img.clampedToExtent()
            u.radius = Float(finalRadius)
            u.intensity = Float(finalSharpen * 1.2)
            img = u.outputImage ?? img
        }
        return img.cropped(to: ext)
    }

    /// hanya bagian akhir yang aktif? (untuk melewati konversi gambar bila tidak perlu)
    var hasPost: Bool {
        abs(shadows) > 0.01 || highlights > 0.01 || abs(contrast) > 0.01 || abs(saturation) > 0.01 || finalSharpen > 0.01
    }
}
