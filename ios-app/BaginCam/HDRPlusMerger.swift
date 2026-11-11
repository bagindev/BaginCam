import AVFoundation
import CoreVideo
import Foundation
import Metal

/// Frame Bayer mentah (uint16, tanpa padding baris) di memori GPU bersama.
struct BayerFrame {
    let buffer: MTLBuffer
    let width: Int
    let height: Int
}

// Struct parameter - layout harus sama persis dengan HDRPlus.metal
private struct AlignParams {
    var w: UInt32, h: UInt32, ntx: UInt32, nty: UInt32, pntx: UInt32, pnty: UInt32
    var tile: Int32, search: Int32, prevScale: Int32
}
private struct WarpParams { var W: UInt32, H: UInt32, ntx: UInt32, nty: UInt32 }
private struct MergeParams { var count: UInt32, maxDiff: Float, invN: Float }

/// HDR+ di GPU: align piramida + spatial robust merge untuk burst Bayer RAW.
/// Port dari pc-lab/robust_merge.py (sudah diuji pada burst iPhone 16 PM).
final class HDRPlusMerger {
    struct Result {
        let buffer: MTLBuffer
        let width: Int
        let height: Int
        let meanWeights: [Float]
        let noiseSD: Float
        let seconds: Double
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pso: [String: MTLComputePipelineState] = [:]

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let lib = d.makeDefaultLibrary() else { return nil }
        device = d
        queue = q
        for name in ["bayer_grey", "downsample2", "align_level", "warp_planes",
                     "blur_h", "blur_v", "merge_accumulate", "planes_to_bayer"] {
            guard let f = lib.makeFunction(name: name),
                  let p = try? d.makeComputePipelineState(function: f) else {
                Log.hdr.error("Pipeline Metal gagal: \(name, privacy: .public)")
                return nil
            }
            pso[name] = p
        }
    }

    /// Salin CVPixelBuffer Bayer 16-bit ke MTLBuffer (buang padding baris).
    func makeFrame(from pb: CVPixelBuffer) -> BayerFrame? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb), w % 2 == 0, h % 2 == 0, bpr >= w * 2,
              let buf = device.makeBuffer(length: w * h * 2, options: .storageModeShared) else { return nil }
        let dst = buf.contents()
        if bpr == w * 2 {
            memcpy(dst, base, w * h * 2)
        } else {
            for y in 0..<h { memcpy(dst + y * w * 2, base + y * bpr, w * 2) }
        }
        return BayerFrame(buffer: buf, width: w, height: h)
    }

    // MARK: merge
    func merge(_ frames: [BayerFrame], noiseReduction: Double = 18, tile: Int = 16, search: Int = 2,
               progress: ((Int, Int) -> Void)? = nil) -> Result? {
        guard let ref = frames.first, frames.count >= 1 else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        let W = ref.width, H = ref.height, pw = W / 2, ph = H / 2, np = pw * ph
        let N = frames.count

        // ukuran piramida: layer0 = superpixel (W/2), lalu /2 terus (sama dengan pc-lab)
        let nLayers = max(1, Int(ceil(log2(Double(min(W, H)) / 64.0))))
        var dims: [(Int, Int)] = []
        var lw = pw, lh = ph
        for _ in 0..<nLayers where min(lw, lh) >= tile * 2 {
            dims.append((lw, lh)); lw /= 2; lh /= 2
        }
        let tiles = dims.map { (max(1, $0.0 / (tile / 2) - 1), max(1, $0.1 / (tile / 2) - 1)) }

        func buf(_ len: Int) -> MTLBuffer? { device.makeBuffer(length: max(len, 16), options: .storageModeShared) }
        let refPyr = dims.compactMap { buf($0.0 * $0.1 * 4) }
        let compPyr = dims.compactMap { buf($0.0 * $0.1 * 4) }
        let aligns = tiles.compactMap { buf($0.0 * $0.1 * 8) }
        guard !dims.isEmpty, refPyr.count == dims.count, compPyr.count == dims.count, aligns.count == dims.count,
              let zeroAlign = buf(tiles[0].0 * tiles[0].1 * 8),
              let refP = buf(np * 16), let refB = buf(np * 16), let compP = buf(np * 16),
              let compB = buf(np * 16), let tmp = buf(np * 16), let acc = buf(np * 16),
              let wsum = buf(4), let out = buf(W * H * 2) else {
            Log.hdr.error("Alokasi buffer GPU gagal")
            return nil
        }
        memset(zeroAlign.contents(), 0, zeroAlign.length)
        memset(acc.contents(), 0, acc.length)

        // --- helper encode ---
        func dispatch(_ enc: MTLComputeCommandEncoder, _ name: String, _ w: Int, _ h: Int) {
            guard let p = pso[name] else { return }
            enc.setComputePipelineState(p)
            let tw = p.threadExecutionWidth
            let th = h == 1 ? 1 : max(1, p.maxTotalThreadsPerThreadgroup / tw)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }
        var rawSize = SIMD2<UInt32>(UInt32(W), UInt32(H))
        var planeSize = SIMD2<UInt32>(UInt32(pw), UInt32(ph))

        func encodePyramid(_ enc: MTLComputeCommandEncoder, _ raw: MTLBuffer, _ pyr: [MTLBuffer]) {
            enc.setBuffer(raw, offset: 0, index: 0)
            enc.setBuffer(pyr[0], offset: 0, index: 1)
            enc.setBytes(&rawSize, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            dispatch(enc, "bayer_grey", pw, ph)
            for l in 1..<dims.count {
                var s = SIMD2<UInt32>(UInt32(dims[l - 1].0), UInt32(dims[l - 1].1))
                enc.setBuffer(pyr[l - 1], offset: 0, index: 0)
                enc.setBuffer(pyr[l], offset: 0, index: 1)
                enc.setBytes(&s, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
                dispatch(enc, "downsample2", dims[l].0, dims[l].1)
            }
        }
        func encodeWarp(_ enc: MTLComputeCommandEncoder, _ raw: MTLBuffer, _ align: MTLBuffer, _ dst: MTLBuffer) {
            var p = WarpParams(W: UInt32(W), H: UInt32(H), ntx: UInt32(tiles[0].0), nty: UInt32(tiles[0].1))
            enc.setBuffer(raw, offset: 0, index: 0)
            enc.setBuffer(align, offset: 0, index: 1)
            enc.setBuffer(dst, offset: 0, index: 2)
            enc.setBytes(&p, length: MemoryLayout<WarpParams>.stride, index: 3)
            dispatch(enc, "warp_planes", pw, ph)
        }
        func encodeBlur(_ enc: MTLComputeCommandEncoder, _ src: MTLBuffer, _ dst: MTLBuffer) {
            enc.setBuffer(src, offset: 0, index: 0)
            enc.setBuffer(tmp, offset: 0, index: 1)
            enc.setBytes(&planeSize, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            dispatch(enc, "blur_h", pw, ph)
            enc.setBuffer(tmp, offset: 0, index: 0)
            enc.setBuffer(dst, offset: 0, index: 1)
            enc.setBytes(&planeSize, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            dispatch(enc, "blur_v", pw, ph)
        }
        func encodeMerge(_ enc: MTLComputeCommandEncoder, comp: MTLBuffer, compBlur: MTLBuffer, maxDiff: Float) {
            var p = MergeParams(count: UInt32(np), maxDiff: maxDiff, invN: 1.0 / Float(N))
            enc.setBuffer(refP, offset: 0, index: 0)
            enc.setBuffer(refB, offset: 0, index: 1)
            enc.setBuffer(comp, offset: 0, index: 2)
            enc.setBuffer(compBlur, offset: 0, index: 3)
            enc.setBuffer(acc, offset: 0, index: 4)
            enc.setBuffer(wsum, offset: 0, index: 5)
            enc.setBytes(&p, length: MemoryLayout<MergeParams>.stride, index: 6)
            dispatch(enc, "merge_accumulate", np, 1)
        }
        func run(_ body: (MTLComputeCommandEncoder) -> Void) -> Bool {
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
            body(enc)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            if let e = cb.error { Log.hdr.error("GPU error: \(String(describing: e), privacy: .public)"); return false }
            return true
        }

        // --- 1. referensi: piramida, plane, blur, acc = ref/N ---
        guard run({ enc in
            encodePyramid(enc, ref.buffer, refPyr)
            encodeWarp(enc, ref.buffer, zeroAlign, refP)
            encodeBlur(enc, refP, refB)
            encodeMerge(enc, comp: refP, compBlur: refB, maxDiff: 0)   // w = 1 -> acc += ref/N
        }) else { return nil }

        // estimasi noise global (sama dengan hdr-plus-swift): mean_sum|ref - blur(ref)|
        let rp = refP.contents().bindMemory(to: SIMD4<Float>.self, capacity: np)
        let rb = refB.contents().bindMemory(to: SIMD4<Float>.self, capacity: np)
        var total: Double = 0
        for i in stride(from: 0, to: np, by: 4) {   // sampling 1/4 cukup untuk rata-rata
            let a: SIMD4<Float> = rp[i]
            let b: SIMD4<Float> = rb[i]
            let dx: Float = abs(a.x - b.x)
            let dy: Float = abs(a.y - b.y)
            let dz: Float = abs(a.z - b.z)
            let dw: Float = abs(a.w - b.w)
            total += Double(dx + dy + dz + dw)
        }
        let noiseSD = Float(total / Double((np + 3) / 4))
        let rev = 0.5 * (36.0 - Double(Int(noiseReduction + 0.5)))
        let robustness = 0.12 * pow(1.3, rev) - 0.4529822
        let maxDiff = robustness > 0 ? noiseSD / Float(robustness) : 0

        // --- 2. tiap frame pembanding ---
        var weights: [Float] = []
        for (i, comp) in frames.enumerated() where i > 0 {
            progress?(i, N - 1)
            guard comp.width == W, comp.height == H else { continue }
            wsum.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            let ok = run { enc in
                encodePyramid(enc, comp.buffer, compPyr)
                for l in stride(from: dims.count - 1, through: 0, by: -1) {
                    let hasPrev = l + 1 < dims.count
                    var p = AlignParams(
                        w: UInt32(dims[l].0), h: UInt32(dims[l].1),
                        ntx: UInt32(tiles[l].0), nty: UInt32(tiles[l].1),
                        pntx: hasPrev ? UInt32(tiles[l + 1].0) : 0, pnty: hasPrev ? UInt32(tiles[l + 1].1) : 0,
                        tile: Int32(tile), search: Int32(search), prevScale: 2)
                    enc.setBuffer(refPyr[l], offset: 0, index: 0)
                    enc.setBuffer(compPyr[l], offset: 0, index: 1)
                    enc.setBuffer(hasPrev ? aligns[l + 1] : zeroAlign, offset: 0, index: 2)
                    enc.setBuffer(aligns[l], offset: 0, index: 3)
                    enc.setBytes(&p, length: MemoryLayout<AlignParams>.stride, index: 4)
                    dispatch(enc, "align_level", tiles[l].0, tiles[l].1)
                }
                encodeWarp(enc, comp.buffer, aligns[0], compP)
                encodeBlur(enc, compP, compB)
                encodeMerge(enc, comp: compP, compBlur: compB, maxDiff: maxDiff)
            }
            guard ok else { return nil }
            let ws = wsum.contents().load(as: UInt32.self)
            weights.append(Float(ws) / (255.0 * Float(np)))
        }

        // --- 3. kembali ke Bayer uint16 ---
        guard run({ enc in
            enc.setBuffer(acc, offset: 0, index: 0)
            enc.setBuffer(out, offset: 0, index: 1)
            enc.setBytes(&rawSize, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            dispatch(enc, "planes_to_bayer", pw, ph)
        }) else { return nil }

        let dt = CFAbsoluteTimeGetCurrent() - t0
        let wtxt = weights.map { String(format: "%.2f", $0) }.joined(separator: " ")
        Log.hdr.info("HDR+ \(N, privacy: .public) frame \(W, privacy: .public)x\(H, privacy: .public): \(dt, format: .fixed(precision: 2), privacy: .public) s, noiseSD \(noiseSD, privacy: .public), maxDiff \(maxDiff, privacy: .public), bobot [\(wtxt, privacy: .public)]")
        return Result(buffer: out, width: W, height: H, meanWeights: weights, noiseSD: noiseSD, seconds: dt)
    }

    // MARK: kembali ke CVPixelBuffer
    /// Buat CVPixelBuffer baru (format sama dengan RAW asli) berisi hasil merge.
    static func makePixelBuffer(from buf: MTLBuffer, width: Int, height: Int, like ref: CVPixelBuffer) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, CVPixelBufferGetPixelFormatType(ref),
                                     attrs as CFDictionary, &out)
        guard st == kCVReturnSuccess, let pb = out else {
            Log.hdr.error("CVPixelBufferCreate gagal (\(st, privacy: .public))")
            return nil
        }
        copy(buf, into: pb, width: width, height: height)
        CVBufferPropagateAttachments(ref, pb)
        return pb
    }

    /// Tulis hasil merge langsung ke buffer RAW asli (cadangan bila CVPixelBufferCreate gagal).
    static func overwrite(_ pb: CVPixelBuffer, with buf: MTLBuffer, width: Int, height: Int) {
        copy(buf, into: pb, width: width, height: height)
    }

    private static func copy(_ buf: MTLBuffer, into pb: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let src = buf.contents()
        for y in 0..<height { memcpy(base + y * bpr, src + y * width * 2, width * 2) }
    }
}

/// Ganti data RAW saat menulis DNG -> metadata Apple (warna, lensa, NoiseProfile) tetap utuh.
final class RawReplacer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    let buffer: CVPixelBuffer
    init(buffer: CVPixelBuffer) { self.buffer = buffer }
    func replacementRawPixelBuffer(for photo: AVCapturePhoto) -> CVPixelBuffer? { buffer }
}
