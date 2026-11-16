import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// v0.36: model penilai komposisi GAIC (Grid Anchor based Image Cropping, Zeng dkk. - kode & bobot MIT,
/// lihat Models/LICENSE-GAIC.txt). Tiga varian backbone dipasang untuk dibandingkan.
enum CompModel: String, CaseIterable, Identifiable {
    case mobile = "MobileNet"
    case shuffle = "ShuffleNet"
    case vgg = "VGG"
    var id: String { rawValue }
    var fileBase: String {
        switch self {
        case .mobile: return "BaginCamComp_mobilenetv2"
        case .shuffle: return "BaginCamComp_shufflenetv2"
        case .vgg: return "BaginCamComp_vgg16"
        }
    }
}

/// Dua model Core ML per varian: gambar -> peta fitur, lalu fitur per kandidat -> skor.
/// Di antaranya RoIAlign + RoDAlign (bagian di dalam / di luar kandidat) dihitung di sini - terjemahan langsung
/// dari roi_align.cpp / rod_align.cpp GAIC, sama dengan tools/comp_gaic.py. File ini tidak memakai UIKit supaya
/// bisa diuji di macOS (tools/comp_model/swift_test).
final class CompScorer {
    static let align = 9
    static let batch = 32
    /// bentuk masukan yang didukung model fitur (lebar, tinggi)
    static let shapes: [(w: Int, h: Int)] = [(256, 352), (352, 256), (256, 448), (448, 256), (256, 256), (256, 320), (320, 256)]

    struct Features {
        let c: Int, h: Int, w: Int          // peta fitur
        let inW: Int, inH: Int              // ukuran gambar masukan model
        let data: [Float]                   // [c][h][w]
    }

    let kind: CompModel
    private let feat: MLModel
    private let head: MLModel
    private let featIn: String, featOut: String, headIn: String, headOut: String

    init?(kind: CompModel, featURL: URL, headURL: URL, units: MLComputeUnits = .all) {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        guard let f = try? MLModel(contentsOf: featURL, configuration: cfg),
              let h = try? MLModel(contentsOf: headURL, configuration: cfg),
              let fi = f.modelDescription.inputDescriptionsByName.keys.first,
              let fo = f.modelDescription.outputDescriptionsByName.keys.first,
              let hi = h.modelDescription.inputDescriptionsByName.keys.first,
              let ho = h.modelDescription.outputDescriptionsByName.keys.first else { return nil }
        self.kind = kind
        feat = f; head = h
        featIn = fi; featOut = fo; headIn = hi; headOut = ho
    }

    static func bundled(_ kind: CompModel) -> CompScorer? {
        func url(_ name: String) -> URL? {
            Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models")
                ?? Bundle.main.url(forResource: name, withExtension: "mlmodelc")
        }
        guard let f = url(kind.fileBase + "_feat"), let h = url(kind.fileBase + "_head") else { return nil }
        return CompScorer(kind: kind, featURL: f, headURL: h)
    }

    /// bentuk masukan dengan rasio terdekat (sisi pendek 256)
    static func inputSize(width: Int, height: Int) -> (w: Int, h: Int) {
        let r = log(Double(max(width, 1)) / Double(max(height, 1)))
        return shapes.min { abs(log(Double($0.w) / Double($0.h)) - r) < abs(log(Double($1.w) / Double($1.h)) - r) } ?? (256, 352)
    }

    // MARK: fitur

    func features(_ image: CGImage) -> Features? {
        let size = Self.inputSize(width: image.width, height: image.height)
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, size.w, size.h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: size.w, height: size.h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: info) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.w, height: size.h))
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [featIn: MLFeatureValue(pixelBuffer: buf)]),
              let out = try? feat.prediction(from: input),
              let arr = out.featureValue(for: featOut)?.multiArrayValue, arr.shape.count == 4 else { return nil }
        let c = arr.shape[1].intValue, h = arr.shape[2].intValue, w = arr.shape[3].intValue
        let data = MLShapedArray<Float>(converting: arr).scalars
        guard data.count == c * h * w, h >= 2, w >= 2 else { return nil }
        return Features(c: c, h: h, w: w, inW: size.w, inH: size.h, data: Array(data))
    }

    // MARK: skor

    /// kotak ternormalisasi (0..1, kiri-atas) terhadap gambar
    func scores(_ f: Features, rects: [CGRect]) -> [Float]? {
        let W = Float(f.inW), H = Float(f.inH)
        return scores(f, pixelBoxes: rects.map { r in
            [Float(r.minX) * W, Float(r.minY) * H, Float(r.maxX) * W - 1, Float(r.maxY) * H - 1]
        })
    }

    /// kotak [x1, y1, x2, y2] dalam piksel gambar masukan model (seperti kandidat saat model dilatih)
    func scores(_ f: Features, pixelBoxes: [[Float]]) -> [Float]? {
        let A = Self.align, C2 = f.c * 2, per = C2 * A * A
        var result: [Float] = []
        result.reserveCapacity(pixelBoxes.count)
        var start = 0
        while start < pixelBoxes.count {
            let n = min(Self.batch, pixelBoxes.count - start)
            var flat = [Float](repeating: 0, count: Self.batch * per)
            for i in 0..<n {
                Self.aligned(f, box: pixelBoxes[start + i], into: &flat, offset: i * per)
            }
            let shaped = MLShapedArray<Float>(scalars: flat, shape: [Self.batch, C2, A, A])
            guard let input = try? MLDictionaryFeatureProvider(dictionary: [headIn: MLFeatureValue(multiArray: MLMultiArray(shaped))]),
                  let out = try? head.prediction(from: input),
                  let arr = out.featureValue(for: headOut)?.multiArrayValue else { return nil }
            let s = MLShapedArray<Float>(converting: arr).scalars
            guard s.count >= n else { return nil }
            result.append(contentsOf: s.prefix(n))
            start += n
        }
        return result
    }

    /// RoIAlign (isi kandidat) + RoDAlign (sisa gambar di luar kandidat), masing-masing 10x10 titik bilinear
    /// lalu rata-rata 2x2 -> 9x9. Ditulis ke `out` sebagai [2C][9][9].
    private static func aligned(_ f: Features, box: [Float], into out: inout [Float], offset: Int) {
        let A = align, P = A + 1
        let scale: Float = 1.0 / 16
        let x1 = box[0] * scale, y1 = box[1] * scale, x2 = box[2] * scale, y2 = box[3] * scale
        let H = f.h, W = f.w
        let binH = max(y2 - y1 + 1, 0) / Float(P - 1), binW = max(x2 - x1 + 1, 0) / Float(P - 1)
        let rodH = (Float(H) - 1.001) / Float(P - 1), rodW = (Float(W) - 1.001) / Float(P - 1)
        var roi = [Float](repeating: 0, count: P * P), rod = [Float](repeating: 0, count: P * P)
        f.data.withUnsafeBufferPointer { d in
            for c in 0..<f.c {
                let base = c * H * W
                func sample(_ h: Float, _ w: Float) -> Float {
                    let hs = max(0, min(Int(h.rounded(.down)), H - 2)), ws = max(0, min(Int(w.rounded(.down)), W - 2))
                    let hr = h - Float(hs), wr = w - Float(ws)
                    let i = base + hs * W + ws
                    return d[i] * (1 - hr) * (1 - wr) + d[i + 1] * (1 - hr) * wr + d[i + W] * hr * (1 - wr) + d[i + W + 1] * hr * wr
                }
                for ph in 0..<P {
                    for pw in 0..<P {
                        let h = Float(ph) * binH + y1, w = Float(pw) * binW + x1
                        roi[ph * P + pw] = (h < 0 || h >= Float(H) || w < 0 || w >= Float(W)) ? 0 : sample(h, w)
                        let gh = Float(ph) * rodH, gw = Float(pw) * rodW
                        rod[ph * P + pw] = (gh >= y1 && gh <= y2 && gw >= x1 && gw <= x2) ? 0 : sample(gh, gw)
                    }
                }
                let oRoi = offset + c * A * A, oRod = offset + (f.c + c) * A * A
                for i in 0..<A {
                    for j in 0..<A {
                        let k = i * P + j
                        out[oRoi + i * A + j] = (roi[k] + roi[k + 1] + roi[k + P] + roi[k + P + 1]) * 0.25
                        out[oRod + i * A + j] = (rod[k] + rod[k + 1] + rod[k + P] + rod[k + P + 1]) * 0.25
                    }
                }
            }
        }
    }

    // MARK: kandidat

    /// kandidat crop dengan rasio sama dengan bingkai (c = sisi ternormalisasi), mirip jangkar grid GAIC:
    /// luas >= ~42 % bingkai (model dilatih pada crop besar), posisi di grid 5x5.
    static func gridCandidates(minSide: CGFloat = 0.65) -> [CGRect] {
        var out: [CGRect] = []
        for c in [0.65, 0.71, 0.77, 0.83, 0.89, 0.95] as [CGFloat] where c >= minSide - 0.001 {
            for ix in 0..<5 {
                for iy in 0..<5 {
                    out.append(CGRect(x: (1 - c) * CGFloat(ix) / 4, y: (1 - c) * CGFloat(iy) / 4, width: c, height: c))
                }
            }
        }
        return out
    }
}
