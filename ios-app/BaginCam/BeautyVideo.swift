import AVFoundation
import CoreImage
import QuartzCore
import Vision

/// v0.41: percantik VIDEO kamera depan (real-time, dipanggil dari antrean video - rekaman & preview sama).
/// Kulit dihaluskan hanya bila: (1) di dalam orang (segmentasi Vision cepat, async - mask boleh telat 1-2 frame),
/// (2) warnanya warna kulit (Cb / Cr), (3) bukan mata / alis / bibir (landmark Vision). Penghalus = guided filter
/// (tepi tetap). Kulit sedikit dicerahkan. Hanya 8-bit (SDR); HLG / Log 10-bit dilewati.
/// Cara kerja sama dengan SINEMA (CinematicProcessor, 4K30 5-6,5 ms/frame).
final class BeautyVideoProcessor {
    // float penuh: varians guided filter (selisih kecil) tidak boleh hilang di half float
    private let ctx = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAf])
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
    private var latestFeat: [CIVector] = []          // dijaga lock: elips lindungan (mata, alis, bibir) dalam piksel
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var frames = 0, applied = 0, withFace = 0
    private var totalMs = 0.0
    private var lastW = 0, lastH = 0
    private var fmtWarned = false
    private var kernelWarned = false
    private var lastLevel = ""
    private let lm = VNDetectFaceLandmarksRequest()
    private static let noEll = CIVector(x: 0, y: 0, z: 0, w: 0)

    /// v0.41.2: guided filter (He, Sun, Tang 2010) + lindungan mata / alis / bibir dari landmark wajah Vision.
    /// Build 100 (blur gaussian besar) dan 101 (dasar dari frame 200-270 px) sama-sama menghapus kontur kelopak, alis,
    /// hidung -> wajah terlihat tidak fokus (IMG_7404, IMG_7406). Guided filter hanya meratakan bagian yang
    /// variasinya kecil (noda, belang, pori) dan mempertahankan tepi; mata / alis / bibir tidak disentuh sama sekali;
    /// sebagian detail halus dikembalikan (`keep`). Diuji offline di frame asli dulu (percantik_video_sim_1118.jpg).
    private static let sqKernel = CIColorKernel(source: """
    kernel vec4 gfSq(__sample p) { return vec4(p.rgb * p.rgb, 1.0); }
    """)
    private static let aKernel = CIColorKernel(source: """
    kernel vec4 gfA(__sample mI, __sample mII, float eps) {
        vec3 v = max(mII.rgb - mI.rgb * mI.rgb, vec3(0.0));
        return vec4(v / (v + vec3(eps)), 1.0);
    }
    """)
    private static let bKernel = CIColorKernel(source: """
    kernel vec4 gfB(__sample mI, __sample a) { return vec4(mI.rgb - a.rgb * mI.rgb, 1.0); }
    """)
    /// s = frame, fs = blur ~1 px, ma / mb = koefisien guided filter (resolusi rendah, dibesarkan), m = mask orang,
    /// e0..e4 = elips lindungan (cx, cy, rx, ry piksel; rx 0 = tidak ada)
    private static let kernel = CIColorKernel(source: """
    float ellP(vec2 p, vec4 e) {
        if (e.z < 1.0) { return 0.0; }
        vec2 d = (p - e.xy) / e.zw;
        return clamp((1.0 - length(d)) / 0.3, 0.0, 1.0);
    }
    kernel vec4 beautyV(__sample s, __sample fs, __sample ma, __sample mb, __sample m,
                        vec4 e0, vec4 e1, vec4 e2, vec4 e3, vec4 e4, float amt, float keep, float lift) {
        vec2 p = destCoord();
        float prot = max(max(ellP(p, e0), ellP(p, e1)), max(max(ellP(p, e2), ellP(p, e3)), ellP(p, e4)));
        vec3 wy = vec3(0.299, 0.587, 0.114);
        float y = dot(s.rgb, wy);
        float cb = 0.5 + dot(s.rgb, vec3(-0.168736, -0.331264, 0.5));
        float cr = 0.5 + dot(s.rgb, vec3(0.5, -0.418688, -0.081312));
        float skin = smoothstep(0.50, 0.54, cr) * (1.0 - smoothstep(0.68, 0.72, cr))
                   * smoothstep(0.26, 0.30, cb) * (1.0 - smoothstep(0.50, 0.54, cb))
                   * smoothstep(0.06, 0.14, y);
        vec3 q = clamp(ma.rgb * s.rgb + mb.rgb, 0.0, 1.0);
        float aL = dot(ma.rgb, wy);
        vec3 sm = q + (s.rgb - fs.rgb) * keep * (1.0 - aL);
        float k = clamp(m.r, 0.0, 1.0) * skin * (1.0 - prot);
        vec3 o = clamp(mix(s.rgb, sm, k * amt), 0.0, 1.0);
        o = mix(o, o * (2.0 - o), k * lift);
        return vec4(o, s.a);
    }
    """)

    private static let okFormats: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                 kCVPixelFormatType_32BGRA]

    /// elips lindungan dari satu wilayah landmark (koordinat normal Vision = koordinat CIImage frame, kiri-bawah)
    private static func ellipse(_ r: VNFaceLandmarkRegion2D?, _ bb: CGRect, W: CGFloat, H: CGFloat,
                                sx: CGFloat, sy: CGFloat, pad: CGFloat) -> CIVector? {
        guard let r, r.pointCount > 1 else { return nil }
        let pts = r.normalizedPoints.map { CGPoint(x: (bb.minX + $0.x * bb.width) * W, y: (bb.minY + $0.y * bb.height) * H) }
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(),
              let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return nil }
        return CIVector(x: (x0 + x1) / 2, y: (y0 + y1) / 2, z: (x1 - x0) / 2 * sx + pad, w: (y1 - y0) / 2 * sy + pad)
    }

    /// antrean mask (async; frame sekarang memakai mask & landmark terbaru)
    private func currentMask(_ pb: CVPixelBuffer) -> (CVPixelBuffer?, [CIVector]) {
        lock.lock()
        let m = latestMask, f = latestFeat
        let start = !maskBusy
        if start { maskBusy = true }
        lock.unlock()
        if start {
            maskQueue.async {
                var r: CVPixelBuffer?
                var feats: [CIVector] = []
                if (try? self.seq.perform([self.req, self.lm], on: pb)) != nil {
                    r = self.req.results?.first?.pixelBuffer
                    let W = CGFloat(CVPixelBufferGetWidth(pb)), H = CGFloat(CVPixelBufferGetHeight(pb))
                    if let face = (self.lm.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }),
                       let l = face.landmarks {
                        let bb = face.boundingBox
                        let pad = bb.width * W * 0.03
                        feats = [
                            Self.ellipse(l.leftEye, bb, W: W, H: H, sx: 1.35, sy: 2.4, pad: pad),
                            Self.ellipse(l.rightEye, bb, W: W, H: H, sx: 1.35, sy: 2.4, pad: pad),
                            Self.ellipse(l.leftEyebrow, bb, W: W, H: H, sx: 1.15, sy: 1.9, pad: pad),
                            Self.ellipse(l.rightEyebrow, bb, W: W, H: H, sx: 1.15, sy: 1.9, pad: pad),
                            Self.ellipse(l.outerLips, bb, W: W, H: H, sx: 1.15, sy: 1.35, pad: pad),
                        ].compactMap { $0 }
                    }
                }
                self.lock.lock()
                self.latestMask = r
                self.latestFeat = feats
                self.maskBusy = false
                self.lock.unlock()
            }
        }
        return (m, f)
    }

    func reset() {
        lock.lock(); latestMask = nil; latestFeat = []; lock.unlock()
    }

    /// frame yang sudah dipercantik, atau nil (format 10-bit / mask belum ada / gagal) -> pakai frame asli
    func process(_ pb: CVPixelBuffer, level: CameraManager.VideoBeautyLevel) -> CVPixelBuffer? {
        guard level.active, ProcessInfo.processInfo.thermalState != .critical else { return nil }     // suhu kritis: dilewati
        guard let kernel = Self.kernel, let sqK = Self.sqKernel, let aK = Self.aKernel, let bK = Self.bKernel else {
            if !kernelWarned {
                kernelWarned = true
                Log.camera.error("! Percantik video: kernel tidak bisa dibuat (utama \(Self.kernel != nil, privacy: .public), kuadrat \(Self.sqKernel != nil, privacy: .public), a \(Self.aKernel != nil, privacy: .public), b \(Self.bKernel != nil, privacy: .public))")
            }
            return nil
        }
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
        lastLevel = level.rawValue
        let (maskOpt, feats) = currentMask(pb)
        guard let mask = maskOpt, let dst = makeBuffer(w, h) else { return nil }
        if !feats.isEmpty { withFace += 1 }
        let src = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
        let ext = src.extent
        let rawMask = CIImage(cvPixelBuffer: mask, options: [.colorSpace: NSNull()])
        let m = rawMask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 2.0])
            .cropped(to: rawMask.extent)
            .transformed(by: CGAffineTransform(scaleX: ext.width / rawMask.extent.width, y: ext.height / rawMask.extent.height))
        let short = Double(min(w, h))
        let fs = src.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(0.8, short / 1080.0)])
            .cropped(to: ext)
        // guided filter di resolusi rendah (1080p: 1/2, 4K: 1/4), koefisien dibesarkan lagi ("fast guided filter")
        // v0.41.4: Standard / Strong di resolusi 2x lebih kecil lagi dengan jari-jari setengah = jangkauan sama,
        // piksel 4x lebih sedikit (Strong build 103: 23-34 ms/frame, preview ikut tersendat)
        let k: CGFloat = (short > 1500 ? 4 : 2) * (level == .soft ? 1 : 2)
        let p = src.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k), highQualityDownsample: true)
        let pe = p.extent
        // v0.41.3: Soft / Standard = Standard / Strong build 102; Strong = porselen (diuji offline: Strong A,
        // percantik_video_sim3_1118.jpg - pori hilang, mata & hidung tetap). Dua lapis guided (B) mengaburkan hidung.
        let (r, eps, keep, amt, lift): (Double, Float, Float, Float, Float) = {
            switch level {
            case .soft: return (4, 0.0015, 0.55, 0.85, 0.08)
            case .standard: return (3, 0.0030, 0.40, 1.0, 0.14)
            default: return (4, 0.0060, 0.15, 1.0, 0.16)
            }
        }()
        func box(_ i: CIImage) -> CIImage {
            i.clampedToExtent().applyingFilter("CIBoxBlur", parameters: ["inputRadius": r]).cropped(to: pe)
        }
        guard let sq = sqK.apply(extent: pe, arguments: [p]) else { return nil }
        let mI = box(p), mII = box(sq)
        guard let a = aK.apply(extent: pe, arguments: [mI, mII, eps]),
              let b = bK.apply(extent: pe, arguments: [mI, a]) else { return nil }
        let up = CGAffineTransform(scaleX: ext.width / pe.width, y: ext.height / pe.height)
        let ma = box(a).transformed(by: up).cropped(to: ext)
        let mb = box(b).transformed(by: up).cropped(to: ext)
        var e = feats
        while e.count < 5 { e.append(Self.noEll) }
        guard let out = kernel.apply(extent: ext, arguments: [src, fs, ma, mb, m, e[0], e[1], e[2], e[3], e[4],
                                                              amt, keep, lift]) else { return nil }
        ctx.render(out, to: dst, bounds: ext, colorSpace: nil)
        CVBufferPropagateAttachments(pb, dst)
        applied += 1
        return dst
    }

    private func stats(_ t0: CFTimeInterval) {
        totalMs += (CACurrentMediaTime() - t0) * 1000
        frames += 1
        guard frames >= 300 else { return }
        Log.camera.notice("Percantik video: \(self.lastW, privacy: .public)x\(self.lastH, privacy: .public), \(self.totalMs / Double(self.frames), format: .fixed(precision: 1), privacy: .public) ms/frame, \(self.lastLevel, privacy: .public), wajah \(self.withFace * 100 / self.frames, privacy: .public)%, diterapkan \(self.applied * 100 / self.frames, privacy: .public)%, suhu \(ProcessInfo.processInfo.thermalState.rawValue, privacy: .public)")
        frames = 0; applied = 0; withFace = 0; totalMs = 0
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
