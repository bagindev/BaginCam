import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Model AI Zoom.
enum SRModel: String, CaseIterable, Identifiable {
    case fast = "Cepat"     // realesr-general-x4v3 (SRVGGNetCompact, 1.2 M param)
    case detail = "Detail"  // RealESRGAN_x4plus (RRDBNet, 16.7 M param)
    var id: String { rawValue }
    var fileName: String { self == .fast ? "BaginCamSR_x4_256" : "BaginCamSRplus_x4_256" }
}

/// Resolusi output (4:3, sisi panjang).
enum OutputMP: Int, CaseIterable, Identifiable {
    case mp12 = 12, mp24 = 24, mp48 = 48
    var id: Int { rawValue }
    var label: String { "\(rawValue)MP" }
    var longSide: Int {
        switch self {
        case .mp12: return 4032
        case .mp24: return 5712
        case .mp48: return 8064
        }
    }
}

/// Super-resolution x4 dengan Core ML (Real-ESRGAN, BSD-3-Clause), per tile 256 px (overlap 16 px).
/// - Tepi tile memakai piksel ASLI di luar area crop (bukan piksel tepi yang diulang) -> tanpa artefak blok.
/// - Output langsung ke skala akhir (outScale <= 4): tiap tile hasil diperkecil ke kanvas akhir,
///   jadi tidak perlu kanvas raksasa x4 di memori (mis. 4032 px x4 = 780 MB).
final class SRUpscaler {
    static let tile = 256
    static let scale = 4
    static let pad = 16

    let modelKind: SRModel
    private var model: MLModel
    private let url: URL
    /// urutan cadangan compute unit bila prediksi gagal (Neural Engine -> GPU -> CPU)
    private var fallbacks: [MLComputeUnits] = [.cpuAndGPU, .cpuOnly]
    /// pesan error terakhir (ditampilkan di status app)
    private(set) var lastError: String?

    static func url(for m: SRModel) -> URL? {
        Bundle.main.url(forResource: m.fileName, withExtension: "mlmodelc", subdirectory: "Models")
            ?? Bundle.main.url(forResource: m.fileName, withExtension: "mlmodelc")
    }

    static func isBundled(_ m: SRModel) -> Bool { url(for: m) != nil }

    init?(model kind: SRModel) {
        guard let url = Self.url(for: kind) else {
            Log.sr.error("Model SR \(kind.rawValue, privacy: .public) tidak ada di bundle")
            return nil
        }
        self.modelKind = kind
        self.url = url
        guard let m = Self.load(url, .all) else { return nil }
        model = m
    }

    private static func load(_ url: URL, _ units: MLComputeUnits) -> MLModel? {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let m = try MLModel(contentsOf: url, configuration: cfg)
            Log.sr.info("Model \(url.lastPathComponent, privacy: .public) dimuat (units \(units.rawValue, privacy: .public)) \(CFAbsoluteTimeGetCurrent() - t0, format: .fixed(precision: 2), privacy: .public) s")
            return m
        } catch {
            Log.sr.error("Muat model gagal (units \(units.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Prediksi 1 tile; bila gagal, ganti compute unit dan coba lagi.
    private func predict(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        while true {
            do {
                let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: input)])
                let result = try model.prediction(from: provider)
                guard let fv = result.featureValue(for: "output") else {
                    lastError = "output 'output' tidak ada (\(result.featureNames.sorted()))"
                    Log.sr.error("\(self.lastError ?? "", privacy: .public)")
                    return nil
                }
                if let pb = fv.imageBufferValue { return pb }
                lastError = "output bukan gambar (tipe \(fv.type.rawValue))"
                Log.sr.error("\(self.lastError ?? "", privacy: .public)")
                return nil
            } catch {
                lastError = String(describing: error)
                Log.sr.error("Prediksi SR gagal: \(self.lastError ?? "", privacy: .public)")
                guard !fallbacks.isEmpty, let m = Self.load(url, fallbacks.removeFirst()) else { return nil }
                model = m
            }
        }
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// BGRA8 di memori (noneSkipFirst + little endian) = sama dengan kCVPixelFormatType_32BGRA
    private static let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Upscale area `crop` dari `image` dengan faktor `outScale` (<= 4).
    func upscale(_ image: CGImage, crop: CGRect, outScale: Double,
                 progress: ((Int, Int) -> Void)? = nil) -> CGImage? {
        let tile = Self.tile, pad = Self.pad, s = Self.scale, core = tile - 2 * pad
        let crop = crop.integral
        let w = Int(crop.width), h = Int(crop.height)
        guard w > 0, h > 0, outScale > 0 else { return nil }
        let k = min(outScale, Double(s))
        let exact = abs(k - Double(s)) < 1e-6
        let cs = Self.space(of: image)

        // sumber = crop + margin pad (piksel asli), dipotong ke batas gambar
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let srcRect = crop.insetBy(dx: CGFloat(-pad), dy: CGFloat(-pad)).intersection(bounds).integral
        guard let srcImg = image.cropping(to: srcRect) else { return nil }
        let sw = Int(srcRect.width), sh = Int(srcRect.height)
        let ox = Int(crop.minX - srcRect.minX), oy = Int(crop.minY - srcRect.minY)
        guard let sctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: cs, bitmapInfo: Self.bitmapInfo) else { return nil }
        sctx.draw(srcImg, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let src = sctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let sbpr = sctx.bytesPerRow

        let ow = max(1, Int((Double(w) * k).rounded())), oh = max(1, Int((Double(h) * k).rounded()))
        guard let octx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: cs, bitmapInfo: Self.bitmapInfo),
              let dst = octx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        octx.interpolationQuality = .high
        let dbpr = octx.bytesPerRow

        var inPB: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, tile, tile, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &inPB) == kCVReturnSuccess, let inBuf = inPB else { return nil }

        let nx = (w + core - 1) / core, ny = (h + core - 1) / core
        var done = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        for ty in 0..<ny {
            for tx in 0..<nx {
                let cx = tx * core, cy = ty * core              // inti tile, koordinat crop
                let bx = cx - pad + ox, by = cy - pad + oy      // awal tile, koordinat sumber

                // isi tile input; hanya di batas gambar asli piksel tepi diulang
                CVPixelBufferLockBaseAddress(inBuf, [])
                if let ib = CVPixelBufferGetBaseAddress(inBuf)?.assumingMemoryBound(to: UInt8.self) {
                    let ibpr = CVPixelBufferGetBytesPerRow(inBuf)
                    let x0 = max(0, -bx), x1 = min(tile, sw - bx)
                    for y in 0..<tile {
                        let sy = min(max(by + y, 0), sh - 1)
                        let srow = src + sy * sbpr
                        let drow = ib + y * ibpr
                        if x1 > x0 { memcpy(drow + x0 * 4, srow + (bx + x0) * 4, (x1 - x0) * 4) }
                        if x0 > 0 { for x in 0..<min(x0, tile) { memcpy(drow + x * 4, srow, 4) } }
                        if x1 < tile { for x in max(x1, 0)..<tile { memcpy(drow + x * 4, srow + (sw - 1) * 4, 4) } }
                    }
                }
                CVPixelBufferUnlockBaseAddress(inBuf, [])

                guard var opb = predict(inBuf) else {
                    Log.sr.error("Prediksi tile \(tx, privacy: .public),\(ty, privacy: .public) gagal")
                    return nil
                }
                if CVPixelBufferGetWidth(opb) != tile * s || CVPixelBufferGetHeight(opb) != tile * s {
                    lastError = "ukuran output SR \(CVPixelBufferGetWidth(opb))x\(CVPixelBufferGetHeight(opb)) tidak sesuai"
                    Log.sr.error("\(self.lastError ?? "", privacy: .public)")
                    return nil
                }
                if CVPixelBufferGetPixelFormatType(opb) != kCVPixelFormatType_32BGRA {
                    guard let conv = toBGRA(opb) else {
                        lastError = "format output SR \(CVPixelBufferGetPixelFormatType(opb)) gagal dikonversi"
                        Log.sr.error("\(self.lastError ?? "", privacy: .public)")
                        return nil
                    }
                    opb = conv
                }

                // salin inti tile hasil ke kanvas
                let coreW = min(core, w - cx), coreH = min(core, h - cy)
                CVPixelBufferLockBaseAddress(opb, .readOnly)
                if let ob = CVPixelBufferGetBaseAddress(opb)?.assumingMemoryBound(to: UInt8.self) {
                    let obpr = CVPixelBufferGetBytesPerRow(opb)
                    if exact {
                        for y in 0..<(coreH * s) {
                            memcpy(dst + (cy * s + y) * dbpr + cx * s * 4, ob + (pad * s + y) * obpr + pad * s * 4, coreW * s * 4)
                        }
                    } else if let tctx = CGContext(data: nil, width: tile * s, height: tile * s, bitsPerComponent: 8,
                                                   bytesPerRow: 0, space: cs, bitmapInfo: Self.bitmapInfo),
                              let tdst = tctx.data?.assumingMemoryBound(to: UInt8.self) {
                        // tile PENUH (termasuk margin pad) digambar, lalu di-clip ke area inti dengan batas
                        // piksel bulat yang sama dengan tile tetangga -> interpolasi di tepi memakai piksel asli,
                        // tidak ada tepi setengah-transparan (bug v0.7.0: garis kotak tiap ~320 px)
                        let tbpr = tctx.bytesPerRow
                        for y in 0..<(tile * s) { memcpy(tdst + y * tbpr, ob + y * obpr, tile * s * 4) }
                        if let timg = tctx.makeImage() {
                            let x0 = Int((Double(cx) * k).rounded()), x1 = Int((Double(cx + coreW) * k).rounded())
                            let y0 = Int((Double(cy) * k).rounded()), y1 = Int((Double(cy + coreH) * k).rounded())
                            let fullX = Double(cx - pad) * k, fullTop = Double(cy - pad) * k, fullSize = Double(tile) * k
                            octx.saveGState()
                            octx.clip(to: CGRect(x: x0, y: oh - y1, width: x1 - x0, height: y1 - y0))
                            octx.draw(timg, in: CGRect(x: fullX, y: Double(oh) - fullTop - fullSize,
                                                       width: fullSize, height: fullSize))
                            octx.restoreGState()
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(opb, .readOnly)
                done += 1
                progress?(done, nx * ny)
            }
        }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        Log.sr.info("SR \(self.modelKind.rawValue, privacy: .public) \(w, privacy: .public)x\(h, privacy: .public) -> \(ow, privacy: .public)x\(oh, privacy: .public) (x\(k, format: .fixed(precision: 2), privacy: .public)): \(nx * ny, privacy: .public) tile, \(dt, format: .fixed(precision: 2), privacy: .public) s")
        return octx.makeImage()
    }

    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var bgraBuffer: CVPixelBuffer?

    private func toBGRA(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if bgraBuffer == nil {
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &bgraBuffer)
        }
        guard let out = bgraBuffer else { return nil }
        ciContext.render(CIImage(cvPixelBuffer: pb), to: out)
        return out
    }

    /// Ruang warna asli gambar (mis. Display P3 dari iPhone) bila RGB, selain itu sRGB.
    static func space(of image: CGImage) -> CGColorSpace {
        if let c = image.colorSpace, c.model == .rgb { return c }
        return colorSpace
    }

    /// Resize kualitas tinggi supaya sisi panjang = longSide.
    static func resize(_ image: CGImage, longSide: Int) -> CGImage? {
        let w = image.width, h = image.height
        let k = Double(longSide) / Double(max(w, h))
        guard abs(k - 1) > 0.001 else { return image }
        return resize(image, width: max(1, Int((Double(w) * k).rounded())), height: max(1, Int((Double(h) * k).rounded())))
    }

    static func resize(_ image: CGImage, width nw: Int, height nh: Int) -> CGImage? {
        if image.width == nw && image.height == nh { return image }
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space(of: image), bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
