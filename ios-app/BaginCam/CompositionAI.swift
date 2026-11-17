import CoreImage
import ImageIO
import SwiftUI
import UIKit
import Vision

// MARK: - AI Komposisi "Susun ulang" (v0.13), ala OPPO Find X10 - offline (Vision Apple)
// 1. Tekan "Susun ulang" -> pindai ~1 detik (bingkai pelangi, "tahan HP").
// 2. Subjek (wajah / badan / objek menonjol) -> 1-3 pilihan komposisi (Sepertiga · Dekat · Lebar) + thumbnail.
// 3. Bingkai saran + titik oranye: geser HP sampai titik masuk lingkaran tengah -> zoom otomatis -> "Pas!".
// Tanpa "Susun ulang": hanya petunjuk ringan (kepala terpotong / ruang kepala). Setelah jepret: versi _CROP.

struct CompGuide: Equatable {
    var target: CGRect      // bingkai saran, ternormalisasi (0..1, kiri-atas) terhadap frame preview
    var subject: CGRect
    var zoom: CGFloat       // zoom tambahan yang disarankan (1 = cukup)
    var dx: CGFloat         // pusat target - pusat frame (+ = kanan)
    var dy: CGFloat         // (+ = bawah)
    var aligned: Bool
    var hint: String
    var kind: String
}

final class CompositionAI: ObservableObject {
    enum Phase { case idle, scanning, guiding }
    enum Variant: Int {
        case neat, close, wide
        case ai                      // v0.36: crop pilihan model GAIC
        var name: String { ["Sepertiga", "Dekat", "Lebar", "AI"][rawValue] }
    }
    struct Candidate: Identifiable {
        let id: Int
        let variant: Variant
        let thumb: UIImage
        let zoom: CGFloat
        var score: Float?            // v0.36: skor komposisi GAIC (kira-kira 1-5)
        var best = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var guide: CompGuide?
    @Published private(set) var candidates: [Candidate] = []
    @Published var selected = 0 { didSet { if selected != oldValue { resetSmooth() } } }
    @Published private(set) var caption = ""
    @Published private(set) var idleHint: String?
    @Published private(set) var message = ""
    /// v0.36: model penilai komposisi (GAIC) - tiga varian dipasang untuk dibandingkan
    @Published var model: CompModel = CompModel(rawValue: UserDefaults.standard.string(forKey: "compModel") ?? "") ?? .mobile {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "compModel") }
    }
    @Published private(set) var frameNote = ""

    /// kemiringan HP (derajat) dari waterpass - di-set dari main
    var roll: Double = 0
    /// batas saran zoom dari zoom sekarang (1 = tidak bisa zoom di mode ini)
    var maxZoom: CGFloat = 2
    /// zoom otomatis saat posisi sudah pas (main)
    var onAutoZoom: ((CGFloat) -> Void)?

    private let queue = DispatchQueue(label: "bagincam.comp", qos: .utility)
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var busy = false
    private var pushCount = 0                 // main
    private var scanStart = Date()            // main
    private var scanTaken = false             // main
    private var lastAutoZoom = Date.distantPast
    private var smooth: CGRect?               // queue
    private var lastKind = ""                 // queue
    private var missing = 0                   // queue
    private var last: CompGuide?              // queue
    private var scorers: [CompModel: CompScorer] = [:]             // dijaga scorerLock
    private var failedScorers = Set<CompModel>()                   // dijaga scorerLock
    private let scorerLock = NSLock()
    private let logQueue = DispatchQueue(label: "bagincam.comp.log", qos: .utility)   // varian lain, hanya untuk log
    private var aiRel: (dx: CGFloat, dy: CGFloat, k: CGFloat)?     // queue: letak crop AI relatif terhadap subjek

    // MARK: kontrol (main)

    func startScan() {
        guide = nil; candidates = []; caption = ""; message = ""; idleHint = nil; frameNote = ""
        selected = 0
        scanStart = Date()
        scanTaken = false
        resetSmooth()
        phase = .scanning
    }

    func close() {
        phase = .idle
        guide = nil
        candidates = []
        caption = ""
        resetSmooth()
    }

    private func resetSmooth() { queue.async { self.smooth = nil; self.missing = 0; self.last = nil } }

    /// dari draw preview (main), frame ukuran layar sebelum LUT
    func push(_ image: CIImage) {
        pushCount += 1
        if phase == .idle && pushCount % 8 != 0 { return }        // v0.15: petunjuk ringan ~0.5x/detik (hemat panas)
        if phase == .scanning {
            guard !scanTaken, Date().timeIntervalSince(scanStart) > 0.3 else { return }
        }
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        let ph = phase, r = roll, mz = maxZoom, md = model
        let variant = candidates.indices.contains(selected) ? candidates[selected].variant : .neat
        if ph == .scanning { scanTaken = true }
        queue.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            switch ph {
            case .idle:
                let h = self.idleAnalyze(image)
                DispatchQueue.main.async { if self.phase == .idle, h != self.idleHint { self.idleHint = h } }
            case .scanning:
                let res = self.scan(image, maxZoom: mz, model: md)
                DispatchQueue.main.async { self.finishScan(res) }
            case .guiding:
                let g = self.analyze(image, variant: variant, roll: r, maxZoom: mz)
                self.last = g
                DispatchQueue.main.async {
                    guard self.phase == .guiding else { return }
                    if g != self.guide { self.guide = g }
                    if let g { self.maybeAutoZoom(g) }
                }
            }
        }
    }

    private func finishScan(_ res: (cands: [Candidate], caption: String, note: String)) {
        let wait = max(0, 1.2 - Date().timeIntervalSince(scanStart))      // animasi pindai minimal ~1 detik
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard self.phase == .scanning else { return }
            if res.cands.isEmpty {
                self.phase = .idle
                self.message = "Subjek tidak jelas - arahkan ke orang / objek lalu coba lagi"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.message = "" }
                return
            }
            self.candidates = res.cands
            self.caption = res.caption
            self.frameNote = res.note
            self.selected = 0
            self.lastAutoZoom = Date()
            self.phase = .guiding
        }
    }

    private func maybeAutoZoom(_ g: CompGuide) {
        guard g.zoom >= 1.12, maxZoom > 1.05, abs(g.dx) < 0.06, abs(g.dy) < 0.06,
              Date().timeIntervalSince(lastAutoZoom) > 1.5 else { return }
        lastAutoZoom = Date()
        resetSmooth()
        onAutoZoom?(g.zoom)
    }

    // MARK: analisis (queue)

    /// v0.15: hanya deteksi wajah (tanpa badan / saliency) - ringan
    private func idleAnalyze(_ image: CIImage) -> String? {
        guard let cg = Self.small(image, 320, ctx) else { return nil }
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])
        guard let f = (req.results ?? []).filter({ $0.confidence > 0.6 }).max(by: { $0.boundingBox.height < $1.boundingBox.height })
        else { return nil }
        let b = f.boundingBox
        let top = 1 - b.maxY
        if top < 0.015 { return "Kepala terpotong - mundur / zoom keluar" }
        if top > 0.35 && b.height > 0.08 { return "Ruang di atas kepala terlalu banyak" }
        return nil
    }

    private func scan(_ image: CIImage, maxZoom: CGFloat, model: CompModel) -> (cands: [Candidate], caption: String, note: String) {
        guard let cg = Self.small(image, 640, ctx), let s = Self.detect(cg, lenient: true) else { return ([], "", "") }
        var rects: [(Variant, CGRect)] = []
        for v in [Variant.neat, .close, .wide] {
            let r = Self.compose(s, variant: v, maxZoom: v == .wide ? 1 : maxZoom, allowMove: true)
            let dup = rects.contains { abs($0.1.width - r.width) < 0.1 && hypot($0.1.midX - r.midX, $0.1.midY - r.midY) < 0.08 }
            if !dup { rects.append((v, r)) }
        }
        var cands: [Candidate] = []
        for (i, (v, r)) in rects.enumerated() {
            let W = CGFloat(cg.width), H = CGFloat(cg.height)
            let c = r.intersection(Self.unit)
            let px = CGRect(x: c.minX * W, y: c.minY * H, width: c.width * W, height: c.height * H).integral
            guard let t = cg.cropping(to: px) else { continue }
            cands.append(Candidate(id: i, variant: v, thumb: UIImage(cgImage: t), zoom: 1 / max(r.width, 0.01)))
        }
        let note = rate(cg, subject: s, rects: rects, cands: &cands, model: model, maxZoom: maxZoom)
        let words = [s.kind] + Self.classify(cg)
        return (cands, words.joined(separator: " · "), note)
    }

    /// v0.36: nilai bingkai sekarang + kandidat aturan dengan model GAIC, tambah kandidat "AI" (crop terbaik dari
    /// grid). Ketiga varian model dihitung dan dicatat di log untuk dibandingkan; `model` yang dipakai di layar.
    private func rate(_ cg: CGImage, subject s: Subject, rects: [(Variant, CGRect)], cands: inout [Candidate],
                      model: CompModel, maxZoom: CGFloat) -> String {
        aiRel = nil
        let ruleRects = rects.map { $0.1.intersection(Self.unit) }
        let grid = CompScorer.gridCandidates(minSide: max(0.65, 1 / max(maxZoom, 1)))
        let all = [Self.unit] + ruleRects + grid
        let names = rects.map { $0.0.name }
        // v0.36.1: varian lain dinilai di antrean latar hanya untuk log (build 85 memuat ketiganya dulu: pindai
        // pertama 10,8 s muat + 3,4 s ShuffleNet)
        let others = CompModel.allCases.filter { $0 != model }
        defer { logQueue.async { for m in others { _ = self.evaluate(m, cg: cg, names: names, all: all) } } }
        guard let sv = evaluate(model, cg: cg, names: names, all: all) else { return "" }
        let g0 = 1 + ruleRects.count
        for i in cands.indices {
            if let k = rects.firstIndex(where: { $0.0 == cands[i].variant }) { cands[i].score = sv[1 + k] }
        }
        if let bi = grid.isEmpty ? nil : (g0..<sv.count).max(by: { sv[$0] < sv[$1] }) {
            let r = all[bi]
            let dup = ruleRects.contains { abs($0.width - r.width) < 0.1 && hypot($0.midX - r.midX, $0.midY - r.midY) < 0.08 }
            let W = CGFloat(cg.width), H = CGFloat(cg.height)
            let px = CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H).integral
            if !dup, let t = cg.cropping(to: px) {
                cands.append(Candidate(id: 9, variant: .ai, thumb: UIImage(cgImage: t), zoom: 1 / max(r.width, 0.01), score: sv[bi]))
                let bw = max(s.box.width, 0.02), bh = max(s.box.height, 0.02)
                aiRel = ((r.midX - s.box.midX) / bw, (r.midY - s.box.midY) / bh, r.width / max(bw, bh))
            }
        }
        var note = ""
        let top = cands.indices.max { (cands[$0].score ?? -9) < (cands[$1].score ?? -9) }
        if let top, let ts = cands[top].score {
            cands[top].best = true
            note = sv[0] >= ts - 0.05 ? String(format: "Bingkai sekarang sudah bagus (%.1f)", sv[0])
                                      : String(format: "Bingkai sekarang %.1f → %@ %.1f", sv[0], cands[top].variant.name, ts)
        }
        return note
    }

    /// model dimuat saat pertama dipakai (aman dipanggil dari dua antrean)
    private func scorer(_ m: CompModel) -> CompScorer? {
        scorerLock.lock()
        defer { scorerLock.unlock() }
        if let sc = scorers[m] { return sc }
        if failedScorers.contains(m) { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        let sc = CompScorer.bundled(m)
        if let sc { scorers[m] = sc } else { failedScorers.insert(m) }
        Log.camera.notice("Komposisi \(m.rawValue, privacy: .public): model \(sc == nil ? "TIDAK ADA" : "dimuat", privacy: .public) (\(CFAbsoluteTimeGetCurrent() - t0, format: .fixed(precision: 2), privacy: .public) s)")
        return sc
    }

    /// skor untuk [bingkai sekarang] + kandidat aturan + grid, dan satu baris log pembanding
    private func evaluate(_ m: CompModel, cg: CGImage, names: [String], all: [CGRect]) -> [Float]? {
        guard let sc = scorer(m) else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let f = sc.features(cg), let sv = sc.scores(f, rects: all), sv.count == all.count else {
            Log.camera.notice("Komposisi \(m.rawValue, privacy: .public): gagal menilai")
            return nil
        }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let g0 = 1 + names.count
        var parts = [String(format: "bingkai %.2f", sv[0])]
        for (i, n) in names.enumerated() { parts.append(String(format: "%@ %.2f", n, sv[1 + i])) }
        if g0 < sv.count, let bi = (g0..<sv.count).max(by: { sv[$0] < sv[$1] }) {
            let r = all[bi]
            parts.append(String(format: "AI %.2f @%.2f,%.2f sisi %.2f", sv[bi], Double(r.midX), Double(r.midY), Double(r.width)))
        }
        Log.camera.notice("Komposisi \(m.rawValue, privacy: .public): \(parts.joined(separator: ", "), privacy: .public) | \(all.count, privacy: .public) kandidat, masukan \(f.inW, privacy: .public)x\(f.inH, privacy: .public), \(dt, format: .fixed(precision: 2), privacy: .public) s")
        return sv
    }

    private func analyze(_ image: CIImage, variant: Variant, roll: Double, maxZoom: CGFloat) -> CompGuide? {
        guard let cg = Self.small(image, 512, ctx) else { return last }
        guard let s = Self.detect(cg, lenient: true) else {
            missing += 1
            if missing > 4 { smooth = nil; return nil }
            return last
        }
        missing = 0
        var r: CGRect
        if variant == .ai, let a = aiRel {
            // crop AI mengikuti subjek: letak & ukuran relatif terhadap kotak subjek saat dipindai
            let c = min(1, max(1 / max(maxZoom, 1), a.k * max(s.box.width, s.box.height)))
            let cx = min(max(s.box.midX + a.dx * s.box.width, 0.2), 0.8)
            let cy = min(max(s.box.midY + a.dy * s.box.height, 0.2), 0.8)
            r = CGRect(x: cx - c / 2, y: cy - c / 2, width: c, height: c)
        } else {
            let v: Variant = variant == .ai ? .neat : variant
            r = Self.compose(s, variant: v, maxZoom: v == .wide ? 1 : maxZoom, allowMove: true)
        }
        if let p = smooth, s.kind == lastKind, hypot(p.midX - r.midX, p.midY - r.midY) < 0.25 {
            let a: CGFloat = 0.35
            r = CGRect(x: p.minX + (r.minX - p.minX) * a, y: p.minY + (r.minY - p.minY) * a,
                       width: p.width + (r.width - p.width) * a, height: p.height + (r.height - p.height) * a)
        }
        smooth = r
        lastKind = s.kind
        let zoom = 1 / max(r.width, 0.01)
        let dx = r.midX - 0.5, dy = r.midY - 0.5
        let tilt = abs(roll) > 2 && abs(roll) < 25
        let panOK = abs(dx) < 0.04 && abs(dy) < 0.04
        let aligned = panOK && zoom < 1.12 && !tilt
        var hint: String
        if aligned {
            hint = "Pas! Jepret sekarang"
        } else if tilt {
            hint = String(format: "Luruskan HP (%.0f°)", roll)
        } else if panOK {
            hint = maxZoom > 1.05 ? String(format: "Tahan... zoom %.1fx", zoom) : "Dekati subjek sedikit"
        } else {
            var parts: [String] = []
            if abs(dx) >= 0.04 { parts.append(dx > 0 ? "kanan" : "kiri") }
            if abs(dy) >= 0.04 { parts.append(dy > 0 ? "bawah" : "atas") }
            hint = "Pindahkan HP ke " + parts.joined(separator: " & ")
        }
        return CompGuide(target: r, subject: s.box, zoom: zoom, dx: dx, dy: dy, aligned: aligned, hint: hint, kind: s.kind)
    }

    // MARK: deteksi subjek

    struct Subject {
        var box: CGRect          // kiri-atas, ternormalisasi
        var anchor: CGPoint      // titik yang ditempatkan di garis sepertiga (mata / pusat objek)
        var kind: String
        var isPerson: Bool
        var face: CGRect?
        var faceTop: CGFloat?
        var faceH: CGFloat
    }

    static func small(_ image: CIImage, _ side: CGFloat, _ ctx: CIContext) -> CGImage? {
        let e = image.extent
        guard e.width > 8, e.height > 8 else { return nil }
        let k = min(1, side / max(e.width, e.height))
        let s = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        return ctx.createCGImage(s, from: CGRect(x: 0, y: 0, width: (e.width * k).rounded(.down), height: (e.height * k).rounded(.down)))
    }

    private static func tl(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// lenient: objek menonjol besar tetap dipakai (pemandangan) untuk Susun ulang
    static func detect(_ cg: CGImage, lenient: Bool = false) -> Subject? {
        let face = VNDetectFaceRectanglesRequest()
        let human = VNDetectHumanRectanglesRequest()
        human.upperBodyOnly = false
        let sal = VNGenerateAttentionBasedSaliencyImageRequest()
        let h = VNImageRequestHandler(cgImage: cg, orientation: .up)
        try? h.perform([face, human, sal])

        let faces = (face.results ?? []).filter { $0.confidence > 0.6 }.map { tl($0.boundingBox) }
            .sorted { $0.width * $0.height > $1.width * $1.height }
        let humans = (human.results ?? []).filter { $0.confidence > 0.5 }.map { tl($0.boundingBox) }

        if let f0 = faces.first, f0.height > 0.03 {
            // wajah yang cukup besar (>= 40 % wajah terbesar) = satu grup
            let group = faces.filter { $0.height > f0.height * 0.4 }
            let faceU = group.dropFirst().reduce(group[0]) { $0.union($1) }
            var box = faceU
            let bodies = humans.filter { hb in group.contains { hb.intersects($0) } }
            if !bodies.isEmpty {
                box = bodies.reduce(box) { $0.union($1) }
            } else {
                // perkiraan setengah badan dari wajah
                box = box.union(CGRect(x: f0.midX - f0.width * 1.1, y: f0.minY, width: f0.width * 2.2, height: f0.height * 4))
            }
            box = box.intersection(unit)
            let eyes = CGPoint(x: faceU.midX, y: faceU.minY + faceU.height * 0.4)
            return Subject(box: box, anchor: eyes, kind: group.count > 1 ? "Grup \(group.count) orang" : "Orang",
                           isPerson: true, face: faceU, faceTop: faceU.minY, faceH: f0.height)
        }
        if let hb = humans.max(by: { $0.width * $0.height < $1.width * $1.height }), hb.height > 0.15 {
            // orang tanpa wajah terlihat (membelakangi / jauh)
            return Subject(box: hb, anchor: CGPoint(x: hb.midX, y: hb.minY + hb.height * 0.12), kind: "Orang",
                           isPerson: true, face: nil, faceTop: hb.minY, faceH: hb.height * 0.12)
        }
        if let obs = sal.results?.first, let objs = obs.salientObjects, !objs.isEmpty {
            let boxes = objs.sorted { $0.confidence > $1.confidence }.map { tl($0.boundingBox) }
            var box = boxes[0]
            for b in boxes.dropFirst() where hypot(b.midX - box.midX, b.midY - box.midY) < 0.2 { box = box.union(b) }
            box = box.intersection(unit)
            let huge = box.width * box.height > 0.8
            if huge && !lenient { return nil }                 // seluruh layar = tidak ada subjek jelas
            return Subject(box: box, anchor: CGPoint(x: box.midX, y: box.midY), kind: huge ? "Pemandangan" : "Objek",
                           isPerson: false, face: nil, faceTop: nil, faceH: 0)
        }
        return nil
    }

    /// label adegan singkat (bahasa Indonesia) untuk keterangan di atas preview
    static func classify(_ cg: CGImage) -> [String] {
        let req = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])
        let skip: Set<String> = ["outdoor", "indoor", "structure", "land", "material", "people", "adult", "person",
                                 "textile", "wood_processed", "clothing", "consumer_electronics", "machine"]
        let map: [String: String] = [
            "beach": "pantai", "sunset_sunrise": "senja", "sky": "langit", "tree": "pohon", "conifer": "pohon",
            "water": "air", "water_body": "air", "sea": "laut", "ocean": "laut", "shore": "tepi laut", "sand": "pasir",
            "mountain": "gunung", "hill": "bukit", "cloudy": "berawan", "cloud": "awan", "building": "gedung",
            "food": "makanan", "dog": "anjing", "cat": "kucing", "flower": "bunga", "car": "mobil", "street": "jalan",
            "road": "jalan", "night_sky": "langit malam", "grass": "rumput", "plant": "tanaman", "foliage": "dedaunan",
            "interior_room": "ruangan", "cityscape": "kota", "bridge": "jembatan", "drink": "minuman", "child": "anak",
            "park": "taman", "garden": "taman", "forest": "hutan", "lake": "danau", "river": "sungai", "snow": "salju",
            "rocks": "batu", "statue": "patung", "motorcycle": "motor", "bird": "burung", "fireworks": "kembang api",
            "portrait": "potret", "selfie": "selfie", "document": "dokumen", "screen": "layar", "computer": "komputer",
        ]
        var out: [String] = []
        for o in (req.results ?? []).prefix(25) where o.confidence > 0.3 && !skip.contains(o.identifier) {
            let w = map[o.identifier] ?? o.identifier.replacingOccurrences(of: "_", with: " ")
            if !out.contains(w) { out.append(w) }
            if out.count >= 3 { break }
        }
        return out
    }

    // MARK: komposisi

    /// bingkai saran (aspek sama dengan frame): subjek di garis sepertiga, ruang kepala, muat dengan margin
    static func compose(_ s: Subject, variant: Variant = .neat, maxZoom: CGFloat, allowMove: Bool) -> CGRect {
        var b = s.box
        let minC = 1 / max(maxZoom, 1)
        if variant == .close, let f = s.face {
            // dekat: kepala sampai dada
            b = CGRect(x: f.midX - f.width * 1.6, y: f.minY - f.height * 0.3, width: f.width * 3.2, height: f.height * 3.4)
                .intersection(unit)
        }
        let big = max(b.width, b.height)
        var c: CGFloat
        switch variant {
        case .wide: c = 1
        case .close: c = s.isPerson ? max(b.height / 0.85, b.width / 0.85) : big / 0.75
        case .neat, .ai: c = s.isPerson ? max(b.height / 0.8, b.width / 0.8) : big / 0.55
        }
        c = min(1, max(minC, c))
        let centerPenalty: CGFloat
        if variant == .close && !s.isPerson { centerPenalty = -0.02 }        // objek dekat: tengah
        else { centerPenalty = s.isPerson ? (s.faceH > 0.12 ? 0 : 0.03) : (big > 0.45 ? 0 : 0.08) }
        let v: CGFloat
        if s.isPerson { v = 1.0 / 3 }
        else if variant == .close || big > 0.45 { v = 0.5 }
        else { v = s.anchor.y < 0.5 ? 1.0 / 3 : 2.0 / 3 }
        var best = unit, bestScore = CGFloat.infinity
        for u in [1.0 / 3, 0.5, 2.0 / 3] as [CGFloat] {
            var x = s.anchor.x - u * c
            var y = s.anchor.y - v * c
            let m = 0.03 * c
            if b.width <= c - 2 * m { x = min(max(x, b.maxX - c + m), b.minX - m) }
            if b.height <= c - 2 * m { y = min(max(y, b.maxY - c + m), b.minY - m) }
            if allowMove {
                // target tetap sebagian besar terlihat
                x = min(max(x, 0.5 - c / 2 - 0.3), 0.5 - c / 2 + 0.3)
                y = min(max(y, 0.5 - c / 2 - 0.3), 0.5 - c / 2 + 0.3)
            } else {
                x = min(max(x, 0), 1 - c)
                y = min(max(y, 0), 1 - c)
            }
            let r = CGRect(x: x, y: y, width: c, height: c)
            let score = hypot(r.midX - 0.5, r.midY - 0.5) + (u == 0.5 ? centerPenalty : 0)
            if score < bestScore { bestScore = score; best = r }
        }
        return best
    }

    // MARK: versi crop setelah jepret

    /// horizon diluruskan (Vision) + crop komposisi. nil = tidak ada yang perlu diperbaiki.
    static func cropVersion(_ data: Data) -> (data: Data, note: String)? {
        guard let src = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let cs = src.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CIContext(options: [.cacheIntermediates: false])
        var img = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
        var notes: [String] = []

        // 1. luruskan horizon (0.7 - 8 derajat)
        if let cg = small(img, 768, ctx) {
            let hr = VNDetectHorizonRequest()
            try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([hr])
            if let hz = hr.results?.first, abs(hz.angle) > 0.7 * .pi / 180, abs(hz.angle) < 8 * .pi / 180 {
                let W = img.extent.width, H = img.extent.height
                let a = -hz.angle
                let rot = img.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2)
                    .concatenating(CGAffineTransform(rotationAngle: a))
                    .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2)))
                let ca = abs(cos(a)), sa = abs(sin(a))
                let k = min(W / (W * ca + H * sa), H / (W * sa + H * ca))
                let cw = (W * k).rounded(.down), ch = (H * k).rounded(.down)
                img = rot.cropped(to: CGRect(x: (W - cw) / 2, y: (H - ch) / 2, width: cw, height: ch))
                img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                notes.append(String(format: "lurus %.1f°", Double(hz.angle * 180 / .pi)))
            }
        }

        // 2. crop komposisi (maks 1.6x agar resolusi tetap cukup)
        guard let cg2 = small(img, 768, ctx) else { return nil }
        var r = unit
        if let s = detect(cg2) {
            let c = compose(s, maxZoom: 1.6, allowMove: false)
            if c.width < 0.97 || abs(c.midX - 0.5) > 0.02 || abs(c.midY - 0.5) > 0.02 {
                r = c
                notes.append("\(s.kind) crop \(Int((c.width * 100).rounded())) %")
            }
        }
        guard !notes.isEmpty else { return nil }
        let w = img.extent.width, h = img.extent.height
        let crop = CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h).integral
        let out = img.cropped(to: crop)
        guard let d = ctx.heifRepresentation(of: out, format: .RGBA8, colorSpace: cs,
                                             options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        else { return nil }
        return (d, notes.joined(separator: ", "))
    }
}

// MARK: - lapisan di preview

struct CompositionOverlay: View {
    @ObservedObject var comp: CompositionAI

    private static let rainbow: [Color] = [.purple, .blue, .cyan, .green, .yellow, .orange, .pink, .purple]

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            ZStack {
                switch comp.phase {
                case .idle:
                    idleLayer
                case .scanning:
                    scanLayer(W: W, H: H)
                case .guiding:
                    guideLayer(W: W, H: H)
                }
            }
        }
    }

    // tombol Susun ulang + petunjuk ringan
    private var idleLayer: some View {
        ZStack {
            VStack {
                if let h = comp.idleHint, comp.message.isEmpty { pill(h, icon: "exclamationmark.triangle.fill", color: .yellow) }
                if !comp.message.isEmpty { pill(comp.message, icon: "viewfinder", color: .white) }
                Spacer()
            }
            .padding(.top, 44)
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { comp.startScan() } label: {
                        Label("Susun ulang", systemImage: "crop")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.bottom, 40).padding(.trailing, 8)
        }
    }

    // bingkai pelangi berputar + "tahan HP"
    private func scanLayer(W: CGFloat, H: CGFloat) -> some View {
        ZStack {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let grad = AngularGradient(colors: Self.rainbow, center: .center, angle: .degrees(t * 180))
                ZStack {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(grad, lineWidth: 10).blur(radius: 8).opacity(0.9)
                    RoundedRectangle(cornerRadius: 6).strokeBorder(grad, lineWidth: 3)
                }
            }
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(.yellow)
                    Text("Tahan HP agar tidak goyang...").foregroundStyle(.white)
                    Button { comp.close() } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                }
                .font(.caption.bold())
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder private func guideLayer(W: CGFloat, H: CGFloat) -> some View {
        let center = CGPoint(x: W / 2, y: H / 2)
        ZStack {
            if let gd = comp.guide {
                let r = CGRect(x: gd.target.minX * W, y: gd.target.minY * H, width: gd.target.width * W, height: gd.target.height * H)
                let tgt = CGPoint(x: r.midX, y: r.midY)
                ZStack {
                    if gd.aligned {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.green, lineWidth: 4)
                    } else {
                        let grad = AngularGradient(colors: Self.rainbow, center: .center)
                        Path { $0.addRoundedRect(in: r, cornerSize: CGSize(width: 6, height: 6)) }
                            .stroke(grad, lineWidth: 9).blur(radius: 6).opacity(0.8)
                        Path { $0.addRoundedRect(in: r, cornerSize: CGSize(width: 6, height: 6)) }
                            .stroke(Color.white.opacity(0.95), lineWidth: 2)
                        // garis sepertiga di dalam bingkai saran
                        Path { p in
                            for i in 1...2 {
                                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                            }
                        }
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        Circle().stroke(Color.white.opacity(0.9), lineWidth: 2).frame(width: 40, height: 40).position(center)
                        // titik oranye: geser HP ke arah titik sampai masuk lingkaran
                        ZStack {
                            Circle().fill(Color.orange).frame(width: 24, height: 24)
                            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.white)
                                .rotationEffect(.radians(Double(atan2(gd.dy * H, gd.dx * W))))
                        }
                        .shadow(radius: 3)
                        .position(tgt)
                    }
                }
                .allowsHitTesting(false)
            }
            VStack(spacing: 6) {
                if !comp.caption.isEmpty {
                    Text(comp.caption).font(.caption2).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white.opacity(0.9))
                }
                if let gd = comp.guide {
                    pill(gd.hint, icon: gd.aligned ? "checkmark.circle.fill" : "move.3d", color: gd.aligned ? .green : .white)
                } else {
                    pill("Mencari subjek...", icon: "viewfinder", color: .white)
                }
                if !comp.frameNote.isEmpty {
                    Text(comp.frameNote).font(.caption2).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.yellow)
                }
                Spacer()
            }
            .padding(.top, 44)
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 8) {
                    Spacer()
                    ForEach(Array(comp.candidates.enumerated()), id: \.element.id) { i, c in
                        Button { comp.selected = i } label: {
                            VStack(spacing: 2) {
                                Image(uiImage: c.thumb).resizable().scaledToFill()
                                    .frame(width: i == comp.selected ? 54 : 44, height: i == comp.selected ? 72 : 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(i == comp.selected ? Color.orange : Color.white.opacity(0.6), lineWidth: i == comp.selected ? 3 : 1))
                                Text(c.variant.name + (c.zoom > 1.1 ? String(format: " %.1fx", Double(c.zoom)) : ""))
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .shadow(radius: 2)
                                if let sc = c.score {
                                    Text((c.best ? "★ " : "") + String(format: "%.1f", sc))
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(c.best ? .yellow : .white.opacity(0.85))
                                        .shadow(radius: 2)
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .overlay(alignment: .bottomLeading) {
                    // v0.36: varian model penilai; ganti = pindai ulang
                    Menu {
                        ForEach(CompModel.allCases) { m in
                            Button { comp.model = m; comp.startScan() } label: {
                                if comp.model == m { Label(m.rawValue, systemImage: "checkmark") } else { Text(m.rawValue) }
                            }
                        }
                    } label: {
                        Text(comp.model.rawValue).font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8).frame(height: 32)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .padding(.leading, 8)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button { comp.close() } label: {
                        Image(systemName: "xmark").font(.footnote.bold())
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.55), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .padding(.trailing, 8)
                }
                .padding(.bottom, 34)
            }
        }
    }

    private func pill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(color)
    }
}
