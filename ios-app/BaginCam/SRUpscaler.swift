import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// AI Zoom: super-resolution x4 dengan Core ML (Real-ESRGAN realesr-general-x4v3, BSD-3-Clause),
/// diproses per tile 256 px (overlap 16 px) supaya muat di Neural Engine dan tanpa sambungan.
final class SRUpscaler {
    static let modelName = "BaginCamSR_x4_256"
    static let tile = 256
    static let scale = 4
    static let pad = 16

    private var model: MLModel
    private let url: URL
    /// urutan cadangan compute unit bila prediksi gagal (Neural Engine -> GPU -> CPU)
    private var fallbacks: [MLComputeUnits] = [.cpuAndGPU, .cpuOnly]
    /// pesan error terakhir (ditampilkan di status app)
    private(set) var lastError: String?

    init?() {
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc", subdirectory: "Models")
                ?? Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            Log.sr.error("Model SR tidak ada di bundle")
            return nil
        }
        self.url = url
        guard let m = Self.load(url, .all) else { return nil }
        model = m
    }

    private static func load(_ url: URL, _ units: MLComputeUnits) -> MLModel? {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        do {
            let m = try MLModel(contentsOf: url, configuration: cfg)
            let inDesc = m.modelDescription.inputDescriptionsByName.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            let outDesc = m.modelDescription.outputDescriptionsByName.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            Log.sr.info("Model SR dimuat (units \(units.rawValue, privacy: .public)) in[\(inDesc, privacy: .public)] out[\(outDesc, privacy: .public)]")
            return m
        } catch {
            Log.sr.error("Muat model SR gagal (units \(units.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
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

    static var isBundled: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: "Models") != nil
            || Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// BGRA8 di memori (noneSkipFirst + little endian) = sama dengan kCVPixelFormatType_32BGRA
    private static let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Upscale x4. progress(selesai, total) dipanggil per tile.
    func upscale(_ image: CGImage, progress: ((Int, Int) -> Void)? = nil) -> CGImage? {
        let w = image.width, h = image.height
        let tile = Self.tile, pad = Self.pad, s = Self.scale, core = tile - 2 * pad
        guard let sctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
        sctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let src = sctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let sbpr = sctx.bytesPerRow

        let ow = w * s, oh = h * s
        guard let octx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: Self.colorSpace, bitmapInfo: Self.bitmapInfo),
              let dst = octx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
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
                let cx = tx * core, cy = ty * core          // posisi inti tile di input
                let ix0 = cx - pad, iy0 = cy - pad          // posisi tile (boleh negatif -> clamp tepi)

                // isi tile input (clamp tepi)
                CVPixelBufferLockBaseAddress(inBuf, [])
                if let ib = CVPixelBufferGetBaseAddress(inBuf)?.assumingMemoryBound(to: UInt8.self) {
                    let ibpr = CVPixelBufferGetBytesPerRow(inBuf)
                    for y in 0..<tile {
                        let sy = min(max(iy0 + y, 0), h - 1)
                        let srow = src + sy * sbpr
                        let drow = ib + y * ibpr
                        let x0 = max(0, -ix0), x1 = min(tile, w - ix0)   // rentang yang ada di dalam gambar
                        if x1 > x0 { memcpy(drow + x0 * 4, srow + (ix0 + x0) * 4, (x1 - x0) * 4) }
                        if x0 > 0 { for x in 0..<x0 { memcpy(drow + x * 4, srow, 4) } }
                        if x1 < tile { for x in max(x1, 0)..<tile { memcpy(drow + x * 4, srow + (w - 1) * 4, 4) } }
                    }
                }
                CVPixelBufferUnlockBaseAddress(inBuf, [])

                // prediksi
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
                    // format lain (mis. ARGB/RGBA) -> konversi ke BGRA lewat Core Image
                    guard let conv = toBGRA(opb) else {
                        lastError = "format output SR \(CVPixelBufferGetPixelFormatType(opb)) gagal dikonversi"
                        Log.sr.error("\(self.lastError ?? "", privacy: .public)")
                        return nil
                    }
                    opb = conv
                }
                if done == 0 {
                    let fmt = CVPixelBufferGetPixelFormatType(opb)
                    Log.sr.info("Output SR \(CVPixelBufferGetWidth(opb), privacy: .public)x\(CVPixelBufferGetHeight(opb), privacy: .public) format \(fmt, privacy: .public)")
                }

                // salin inti tile hasil ke kanvas output
                CVPixelBufferLockBaseAddress(opb, .readOnly)
                if let ob = CVPixelBufferGetBaseAddress(opb)?.assumingMemoryBound(to: UInt8.self) {
                    let obpr = CVPixelBufferGetBytesPerRow(opb)
                    let copyW = min(core, w - cx) * s, copyH = min(core, h - cy) * s
                    for y in 0..<copyH {
                        memcpy(dst + (cy * s + y) * dbpr + cx * s * 4,
                               ob + (pad * s + y) * obpr + pad * s * 4, copyW * 4)
                    }
                }
                CVPixelBufferUnlockBaseAddress(opb, .readOnly)
                done += 1
                progress?(done, nx * ny)
            }
        }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        Log.sr.info("SR \(w, privacy: .public)x\(h, privacy: .public) -> \(ow, privacy: .public)x\(oh, privacy: .public): \(nx * ny, privacy: .public) tile, \(dt, format: .fixed(precision: 2), privacy: .public) s")
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

    /// Resize kualitas tinggi supaya sisi panjang = longSide.
    static func resize(_ image: CGImage, longSide: Int) -> CGImage? {
        let w = image.width, h = image.height
        let k = Double(longSide) / Double(max(w, h))
        guard abs(k - 1) > 0.001 else { return image }
        let nw = max(1, Int((Double(w) * k).rounded())), nh = max(1, Int((Double(h) * k).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
