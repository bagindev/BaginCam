// Uji CompScorer.swift di macOS (CI): skor harus sama dengan acuan PyTorch dari convert_gaic.py.
// Pakai: comp_test <folder_mlmodelc> <uji_256x352.png> <acuan.json>
import CoreGraphics
import CoreML
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 4 else { print("argumen: <folder_mlmodelc> <png> <acuan.json>"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("gambar uji tidak terbaca"); exit(2) }
guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[3])),
      let ref = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let boxesAny = ref["boxes"] as? [[NSNumber]], let scoresAny = ref["scores"] as? [String: [NSNumber]] else {
    print("acuan tidak terbaca"); exit(2)
}
let boxes = boxesAny.map { $0.map { $0.floatValue } }
let names: [(CompModel, String)] = [(.mobile, "mobilenetv2"), (.shuffle, "shufflenetv2"), (.vgg, "vgg16")]
var failed = false
print("gambar \(img.width)x\(img.height), \(boxes.count) kotak")
for (kind, key) in names {
    let f = dir.appendingPathComponent(kind.fileBase + "_feat.mlmodelc"), h = dir.appendingPathComponent(kind.fileBase + "_head.mlmodelc")
    guard let scorer = CompScorer(kind: kind, featURL: f, headURL: h, units: .cpuOnly), let want = scoresAny[key]?.map({ $0.floatValue }) else {
        print("\(key): model / acuan tidak ada"); failed = true; continue
    }
    let t0 = Date()
    guard let feats = scorer.features(img), let got = scorer.scores(feats, pixelBoxes: boxes), got.count == want.count else {
        print("\(key): prediksi gagal"); failed = true; continue
    }
    let dt = Date().timeIntervalSince(t0)
    let err = zip(got, want).map { abs($0 - $1) }.max() ?? 0
    let bestGot = got.indices.max { got[$0] < got[$1] } ?? -1, bestWant = want.indices.max { want[$0] < want[$1] } ?? -1
    print(String(format: "%@: fitur %dx%dx%d, selisih skor maks %.4f, terbaik #%d (acuan #%d), %.2f s", key, feats.c, feats.h, feats.w, err, bestGot, bestWant, dt))
    // kotak ternormalisasi harus memberi hasil yang sama dengan kotak piksel
    let W = CGFloat(feats.inW), H = CGFloat(feats.inH)
    let rects = boxes.map { CGRect(x: CGFloat($0[0]) / W, y: CGFloat($0[1]) / H, width: CGFloat($0[2] - $0[0] + 1) / W, height: CGFloat($0[3] - $0[1] + 1) / H) }
    if let g2 = scorer.scores(feats, rects: rects) {
        let e2 = zip(g2, got).map { abs($0 - $1) }.max() ?? 0
        print(String(format: "   kotak ternormalisasi vs piksel: selisih maks %.4f", e2))
        if e2 > 0.02 { failed = true }
    } else { failed = true }
    if err > 0.08 { failed = true }
}
print("kandidat grid: \(CompScorer.gridCandidates().count)")
exit(failed ? 1 : 0)
