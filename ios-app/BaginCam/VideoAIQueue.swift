import Foundation
import SwiftUI
import UIKit

/// v0.40: antrean AI video (seperti antrean foto). Dulu "AI setelah rekam" membuka layar AI yang mematikan kamera
/// sampai selesai (1080p ~1,4 s/frame: 30 s video = ~20 menit). Sekarang video masuk antrean dan diproses satu per
/// satu di latar selagi app terbuka; kamera tetap bisa dipakai. AI DITAHAN (potongan yang sudah jadi disimpan,
/// lanjut otomatis) saat: merekam / memotret / foto diproses, HP panas (suhu >= 2), atau app ditinggal.
/// Pekerjaan aktif memakai AIJob (Documents/AIJob, bisa dilanjutkan); yang menunggu ada di Documents/AIQueue.
/// Semua state di main thread.
final class VideoAIQueue: ObservableObject {
    static let shared = VideoAIQueue()

    struct Entry: Codable {
        var input: String              // relatif ke Documents (salinan di AIQueue, dihapus setelah selesai)
        var model: String, mode: String, strength: Double, stabilize: Bool, saveTo: String
    }

    /// jumlah video di antrean termasuk yang sedang / tertunda diproses
    @Published private(set) var count = 0
    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""

    /// kamera sedang sibuk (rekam / jepret / foto diproses) -> AI ditahan. Diisi ContentView.
    var cameraBusy: () -> Bool = { false }
    /// dipanggil saat `running` berubah (layar tetap nyala)
    var onRunningChange: (() -> Void)?

    private var entries: [Entry] = []
    private var upscaler: VideoUpscaler?
    private var timer: Timer?
    private var pauseReason = ""
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    static var dir: URL { AIJob.docs.appendingPathComponent("AIQueue", isDirectory: true) }
    static var file: URL { dir.appendingPathComponent("queue.json") }

    private init() {
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: Self.file))) ?? []
        updateCount()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poke() }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            // potongan yang sedang ditulis diselesaikan dulu (waktu tambahan dari iOS)
            if self.bgTask == .invalid {
                self.bgTask = UIApplication.shared.beginBackgroundTask(withName: "AI video") { [weak self] in self?.endBg() }
            }
            self.pause("app ditinggal")
        })
        if count > 0 { Log.sr.notice("Antrean AI video: \(self.count, privacy: .public) video tertunda dari sesi sebelumnya") }
        poke()
    }

    /// video masuk antrean. `move`: file sumber boleh dipindah (salinan sementara); false = disalin (file asli tetap).
    func enqueue(_ url: URL, options o: UpscaleOptions, move: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let dst = Self.dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))_\(url.lastPathComponent)")
        do {
            if move { try fm.moveItem(at: url, to: dst) } else { try fm.copyItem(at: url, to: dst) }
        } catch {
            Log.sr.error("Antrean AI video: gagal menyalin \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            status = "AI video: gagal masuk antrean"
            return
        }
        let docsPath = AIJob.docs.resolvingSymlinksInPath().path + "/"
        let rel = String(dst.resolvingSymlinksInPath().path.dropFirst(docsPath.count))
        entries.append(Entry(input: rel, model: o.model.rawValue, mode: o.mode.rawValue, strength: o.strength,
                             stabilize: o.stabilize, saveTo: o.saveTo.rawValue))
        save()
        updateCount()
        Log.sr.notice("Antrean AI video: +\(url.lastPathComponent, privacy: .public) -> \(self.count, privacy: .public) video")
        status = "AI video: masuk antrean (\(count) video)"
        poke()
    }

    /// cek ulang: tahan bila kamera sibuk / panas / app di latar, mulai bila bebas
    func poke() {
        if running {
            if let r = blockReason() { pause(r) }
            return
        }
        guard count > 0 else { return }
        if let r = blockReason() {
            let s = "AI video menunggu (\(r)) · \(count) video"
            if s != status { status = s }
            return
        }
        runNext()
    }

    /// buang semua video yang menunggu + pekerjaan tertunda (hanya bila tidak sedang berjalan)
    func clearAll() {
        guard !running else { return }
        for e in entries { try? FileManager.default.removeItem(at: AIJob.docs.appendingPathComponent(e.input)) }
        entries = []
        save()
        AIJob.load()?.finish()
        AIJob.clear()
        updateCount()
        status = "Antrean AI video dikosongkan"
        Log.sr.notice("Antrean AI video: dikosongkan")
    }

    private func blockReason() -> String? {
        if UIApplication.shared.applicationState != .active { return "app di latar" }
        if cameraBusy() { return "kamera dipakai" }
        if ProcessInfo.processInfo.thermalState.rawValue >= 2 { return "HP panas" }
        return nil
    }

    private func pause(_ reason: String) {
        guard running, let up = upscaler else { return }
        pauseReason = reason
        up.pause()
        upscaler = nil              // pause() sekali saja; run() selesai sendiri setelah potongan disimpan
        Log.sr.notice("Antrean AI video: ditahan (\(reason, privacy: .public))")
    }

    private func runNext() {
        var pending = AIJob.load()
        var entry: Entry?
        if pending == nil {
            AIJob.clear()
            while !entries.isEmpty {
                let e = entries.removeFirst()
                if FileManager.default.fileExists(atPath: AIJob.docs.appendingPathComponent(e.input).path) { entry = e; break }
            }
            save()
            guard entry != nil else { updateCount(); return }
        }
        setRunning(true)
        pauseReason = ""
        progress = pending.map { $0.frames > 0 ? Double($0.done) / Double($0.frames) : 0 } ?? 0
        let up = VideoUpscaler()
        upscaler = up
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var name = ""
            do {
                if pending == nil, let e = entry {
                    let url = AIJob.docs.appendingPathComponent(e.input)
                    var o = UpscaleOptions()
                    o.model = SRModel(rawValue: e.model) ?? .fast
                    o.mode = UpscaleMode(rawValue: e.mode) ?? .enlarge
                    o.strength = e.strength
                    o.stabilize = e.stabilize
                    o.saveTo = VideoSaveTo(rawValue: e.saveTo) ?? .photos
                    let info = try await VideoUpscaler.inspect(url, o)
                    if info.note.contains("tidak didukung") {
                        try? FileManager.default.removeItem(at: url)
                        throw UpscaleError.msg(info.note)
                    }
                    pending = try AIJob.create(input: url, options: o, frames: info.frames, deleteInput: true)
                }
                guard let j = pending else { throw UpscaleError.msg("pekerjaan hilang") }
                name = j.inputName
                await MainActor.run { self.status = "AI video: \(name) mulai" }
                let t0 = CFAbsoluteTimeGetCurrent()
                let (nj, out) = try await up.run(j) { d, t, per in
                    DispatchQueue.main.async {
                        self.progress = t > 0 ? Double(d) / Double(t) : 0
                        let left = Double(max(t - d, 0)) * per
                        let more = self.count > 1 ? " · \(self.count - 1) lagi" : ""
                        self.status = String(format: "AI video %d%% · sisa ~%@%@", Int(self.progress * 100), Self.dur(left), more)
                    }
                }
                if let out {
                    let msg = await VideoUpscaler.save(out, to: nj.options.saveTo)
                    nj.finish()
                    let dt = CFAbsoluteTimeGetCurrent() - t0
                    Log.sr.notice("Antrean AI video: selesai \(out.lastPathComponent, privacy: .public) (\(dt, format: .fixed(precision: 0), privacy: .public) s sesi ini). \(msg, privacy: .public)")
                    await MainActor.run { self.status = "AI video selesai: \(msg)" }
                } else {
                    await MainActor.run {
                        self.status = "AI video ditahan (\(self.pauseReason.isEmpty ? "dijeda" : self.pauseReason)) di \(nj.done)/\(nj.frames) frame - lanjut otomatis"
                    }
                }
            } catch {
                // pekerjaan rusak dibuang supaya antrean tidak macet (sumber sudah tersimpan di Foto / Files)
                Log.sr.error("Antrean AI video: gagal \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                AIJob.load()?.finish()
                AIJob.clear()
                await MainActor.run { self.status = "AI video gagal: \(error.localizedDescription)" }
            }
            await MainActor.run {
                self.upscaler = nil
                self.setRunning(false)
                self.updateCount()
                self.endBg()
            }
        }
    }

    private func setRunning(_ r: Bool) {
        guard r != running else { return }
        running = r
        onRunningChange?()
    }

    private func endBg() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: Self.file, options: .atomic)
    }

    private func updateCount() {
        let n = entries.count + (AIJob.load() != nil ? 1 : 0)
        if n != count { count = n }
        if n == 0 && !running { progress = 0 }
    }

    static func dur(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d j %02d m", t / 3600, (t % 3600) / 60)
            : (t >= 60 ? String(format: "%d m %02d s", t / 60, t % 60) : "\(t) s")
    }
}

/// baris kecil status antrean AI video (di bawah status kamera)
struct VideoAIQueueLine: View {
    @ObservedObject var q: VideoAIQueue
    var body: some View {
        if q.count > 0 || !q.status.isEmpty && q.running {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                if q.running { ProgressView(value: q.progress).tint(.purple).frame(width: 60) }
                Text(q.status.isEmpty ? "AI video: \(q.count) video" : q.status)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
