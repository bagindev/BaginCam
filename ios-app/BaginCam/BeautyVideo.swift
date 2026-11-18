import AVFoundation
import CoreImage
import QuartzCore
import Vision

/// v0.41: percantik VIDEO kamera depan (real-time, dipanggil dari antrean video - rekaman & preview sama).
/// Kulit dihaluskan hanya bila: (1) di dalam orang (segmentasi Vision cepat, async - mask boleh telat 1-2 frame),
/// (2) warnanya warna kulit (Cb / Cr), (3) teksturnya halus (pori / noda kecil). Tepi kuat - mata, alis, bibir,
/// rambut, tepi wajah - dibiarkan tajam. Kulit sedikit dicerahkan. Hanya 8-bit (SDR); HLG / Log 10-bit dilewati.
/// Cara kerja sama dengan SINEMA (CinematicProcessor, 4K30 5-6,5 ms/frame).
final class BeautyVideoProcessor {
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let seq = VNSequenceRequestHandler()
    private let req: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .fast
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let maskQueue = DispatchQueue(label: "bagincam.beautymask", qos: .userInitiated)
    private let lock = NSLock()
    private var maskBusy = false
    private var latestMask: CVPixelBuffer?
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var frames = 0, applied = 0
    private var totalMs = 0.0
    private var lastW = 0, lastH = 0
    private var fmtWarned = false
    private var method = ""

    /// v0.41.1: pemisahan frekuensi. s = frame, fs = blur tipis (~1 px, batas detail halus), b = dasar halus yang
    /// menghormati tepi (CIEdgePreserveUpsample dari frame kecil), m = mask orang.
    /// Build 100 mencampur kulit 75-95 % dengan blur gaussian besar (Strong 4K ~11 px) -> pori, bulu mata, kontur
    /// mata / hidung ikut hilang = wajah terlihat tidak fokus (IMG_7404). Sekarang yang dihaluskan hanya pita tengah
    /// (noda, belang, jerawat kecil); detail halus (s - fs) dikembalikan `keep` bagian -> wajah tetap tajam.
    private static let kernel = CIColorKernel(source: """
    kernel vec4 beautyV(__sample s, __sample fs, __sample b, __sample m, float amt, float keep, float lift) {
        vec3 wy = vec3(0.299, 0.587, 0.114);
        float y = dot(s.rgb, wy);
        float cb = 0.5 + dot(s.rgb, vec3(-0.168736, -0.331264, 0.5));
        float cr = 0.5 + dot(s.rgb, vec3(0.5, -0.418688, -0.081312));
        float skin = smoothstep(0.50, 0.54, cr) * (1.0 - smoothstep(0.68, 0.72, cr))
                   * smoothstep(0.26, 0.30, cb) * (1.0 - smoothstep(0.50, 0.54, cb))
                   * smoothstep(0.06, 0.14, y);
        // tepi kuat (garis mata, bibir, lubang hidung) tetap dari frame asli
        float d = abs(dot(fs.rgb, wy) - dot(b.rgb, wy));
        float tex = 1.0 - smoothstep(0.06, 0.20, d);
        float k = clamp(m.r, 0.0, 1.0) * skin;
        float w = k * tex * amt;
        vec3 base = mix(fs.rgb, b.rgb, w);
        vec3 o = clamp(base + (s.rgb - fs.rgb) * (1.0 - w * (1.0 - keep)), 0.0, 1.0);
        o = mix(o, o * (2.0 - o), k * lift);
        return vec4(o, s.a);
    }
    """)

    private static let okFormats: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                 kCVPixelFormatType_32BGRA]

    /// antrean mask (async; frame sekarang memakai mask terbaru)
    private func currentMask(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        let m = latestMask
        let start = !maskBusy
        if start { maskBusy = true }
        lock.unlock()
        if start {
            maskQueue.async {
                var r: CVPixelBuffer?
                if (try? self.seq.perform([self.req], on: pb)) != nil { r = self.req.results?.first?.pixelBuffer }
                self.lock.lock()
                self.latestMask = r
                self.maskBusy = false
                self.lock.unlock()
            }
        }
        return m
    }

    func reset() {
        lock.lock(); latestMask = nil; lock.unlock()
    }

    /// frame yang sudah dipercantik, atau nil (format 10-bit / mask belum ada / gagal) -> pakai frame asli
    func process(_ pb: CVPixelBuffer, level: CameraManager.BeautyLevel) -> CVPixelBuffer? {
        guard level.active, let kernel = Self.kernel,
              ProcessInfo.processInfo.thermalState != .critical else { return nil }     // suhu kritis: dilewati
        guard Self.okFormats.contains(CVPixelBufferGetPixelFormatType(pb)) else {
            if !fmtWarned {
                fmtWarned = true
                Log.camera.notice("Percantik video: dilewati, format 10-bit (HLG / Log) - hanya SDR 8-bit")
            }
            return nil
        }
        fmtWarned = false
        let t0 = CACurrentMediaTime()
        defer { stats(t0) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        lastW = w; lastH = h
        guard let mask = currentMask(pb), let dst = makeBuffer(w, h) else { return nil }
        let src = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
        let ext = src.extent
        let rawMask = CIImage(cvPixelBuffer: mask, options: [.colorSpace: NSNull()])
        let m = rawMask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 2.0])
            .cropped(to: rawMask.extent)
            .transformed(by: CGAffineTransform(scaleX: ext.width / rawMask.extent.width, y: ext.height / rawMask.extent.height))
        let short = Double(min(w, h))
        let strong = level == .strong
        // detail halus: blur ~1 px (1080p) - yang lebih halus dari ini dipertahankan
        let fs = src.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(0.8, short / 1080.0)])
            .cropped(to: ext)
        // dasar halus: frame diperkecil (sisi pendek 270 / 200 px - noda hilang) lalu dibesarkan lagi mengikuti
        // tepi frame asli (bilateral bersama) -> kontur wajah tetap di tempatnya
        let small = src.transformed(by: CGAffineTransform(scaleX: CGFloat((strong ? 200 : 270) / short),
                                                          y: CGFloat((strong ? 200 : 270) / short)), highQualityDownsample: true)
        let b: CIImage
        if let ep = CIFilter(name: "CIEdgePreserveUpsampleFilter", parameters: [
            kCIInputImageKey: src, "inputSmallImage": small, "inputSpatialSigma": 3.0, "inputLumaSigma": strong ? 0.12 : 0.09,
        ]), let o = ep.outputImage {
            b = o.cropped(to: ext)
            method = "tepi"
        } else {
            b = src.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": short / 1080.0 * 3.0])
                .cropped(to: ext)
            method = "gaussian"
        }
        let amt: Float = strong ? 1.0 : 0.85
        let keep: Float = strong ? 0.5 : 0.7
        let lift: Float = strong ? 0.16 : 0.10
        guard let out = kernel.apply(extent: ext, arguments: [src, fs, b, m, amt, keep, lift]) else { return nil }
        ctx.render(out, to: dst, bounds: ext, colorSpace: nil)
        CVBufferPropagateAttachments(pb, dst)
        applied += 1
        return dst
    }

    private func stats(_ t0: CFTimeInterval) {
        totalMs += (CACurrentMediaTime() - t0) * 1000
        frames += 1
        guard frames >= 300 else { return }
        Log.camera.notice("Percantik video: \(self.lastW, privacy: .public)x\(self.lastH, privacy: .public), \(self.totalMs / Double(self.frames), format: .fixed(precision: 1), privacy: .public) ms/frame, dasar \(self.method, privacy: .public), diterapkan \(self.applied * 100 / self.frames, privacy: .public)%, suhu \(ProcessInfo.processInfo.thermalState.rawValue, privacy: .public)")
        frames = 0; applied = 0; totalMs = 0
    }

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != w || poolH != h {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p; poolW = w; poolH = h
        }
        guard let pool else { return nil }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        return dst
    }
}
