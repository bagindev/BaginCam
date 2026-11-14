import Foundation
import OSLog
import UIKit

/// v0.17.1: log app disimpan ke file (Documents/Logs/BaginCam_yyyyMMdd.txt) supaya bisa tes TANPA kabel.
/// Isi = semua pesan Log.* (subsystem dev.bagincam.app) proses ini, dibaca dari OSLogStore tiap 15 detik
/// dan saat app ditinggal. Diambil dari Windows:
///   pymobiledevice3 apps pull --documents dev.bagincam.app.<team> /Documents/Logs <folder lokal>
/// atau app Files > BaginCam > Logs, atau tombol "Bagikan log" di Pengaturan.
final class LogFile {
    static let shared = LogFile()

    private let queue = DispatchQueue(label: "bagincam.logfile", qos: .utility)
    private var lastDate: Date                 // queue
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
    }

    static var todayURL: URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return dir.appendingPathComponent("BaginCam_\(f.string(from: Date())).txt")
    }

    private init() { lastDate = Date().addingTimeInterval(-5) }

    /// v0.20: model HP, mis. "iPhone17,2 (16 Pro Max)" - untuk uji di iPhone 17/18 Pro Max
    static let model: String = {
        var u = utsname()
        uname(&u)
        let id = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let names = ["iPhone17,1": "16 Pro", "iPhone17,2": "16 Pro Max", "iPhone18,1": "17 Pro", "iPhone18,2": "17 Pro Max"]
        return names[id].map { "\(id) (\($0))" } ?? id
    }()

    /// main
    func start() {
        guard timer == nil else { return }
        let info = Bundle.main.infoDictionary
        let ver = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let th = ProcessInfo.processInfo.thermalState.rawValue
        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        let batt = dev.batteryLevel >= 0 ? "\(Int(dev.batteryLevel * 100))%" : "?"
        let charging = dev.batteryState == .charging || dev.batteryState == .full
        write("\n===== \(Self.stamp(Date())) BaginCam \(ver) · \(Self.model) · iOS \(dev.systemVersion) · suhu \(th) · baterai \(batt)\(charging ? " (mengisi)" : "") =====\n")
        cleanup()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.flush() }
        let nc = NotificationCenter.default
        for n in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                  UIApplication.willTerminateNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.flush(wait: true) })
        }
    }

    /// ambil pesan baru dari OSLogStore -> tambahkan ke file
    func flush(wait: Bool = false) {
        var bg = UIBackgroundTaskIdentifier.invalid
        if wait { bg = UIApplication.shared.beginBackgroundTask(withName: "log") { UIApplication.shared.endBackgroundTask(bg) } }
        queue.async {
            self.export()
            if bg != .invalid { DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(bg) } }
        }
    }

    private func export() {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
        let pos = store.position(date: lastDate)
        let pred = NSPredicate(format: "subsystem == %@", "dev.bagincam.app")
        guard let entries = try? store.getEntries(at: pos, matching: pred) else { return }
        var out = ""
        var newest = lastDate
        for e in entries {
            guard let l = e as? OSLogEntryLog, l.date > lastDate else { continue }
            let lvl = l.level == .error || l.level == .fault ? " !" : ""
            out += "\(Self.stamp(l.date)) [\(l.category)]\(lvl) \(l.composedMessage)\n"
            if l.date > newest { newest = l.date }
        }
        lastDate = newest
        if !out.isEmpty { write(out) }
    }

    private func write(_ s: String) {
        let url = Self.todayURL
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        guard let d = s.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(d)
            try? h.close()
        } else {
            try? d.write(to: url)
        }
    }

    /// simpan 14 hari terakhir saja
    private func cleanup() {
        queue.async {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let limit = Date().addingTimeInterval(-14 * 86400)
            for f in files {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                if d < limit { try? fm.removeItem(at: f) }
            }
        }
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }

    static var todaySize: String {
        let n = (try? FileManager.default.attributesOfItem(atPath: todayURL.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
