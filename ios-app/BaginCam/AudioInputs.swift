import AVFoundation
import Combine

/// v0.42.3: pemilih mikrofon (iPhone / USB-C / kabel / Bluetooth) untuk VIDEO - jalan di iOS 18.
/// Dulu sesi kamera mengatur sesi audio sendiri: Bluetooth tidak pernah dipakai, mikrofon eksternal tergantung pilihan
/// iOS, dan tidak ada daftar pilihan. Sekarang sesi audio app diatur di sini (playAndRecord + videoRecording,
/// Bluetooth diizinkan) lalu input pilihan pengguna dipasang (`setPreferredInput`). Daftar diperbarui saat perangkat
/// dicolok / dilepas. Semua publik di main.
final class AudioInputs: ObservableObject {
    static let shared = AudioInputs()

    struct Item: Identifiable, Equatable {
        let id: String          // uid port
        let name: String
        let kind: String        // label jenis (Internal / USB / Kabel / Bluetooth / ...)
        var label: String { kind.isEmpty ? name : "\(name) (\(kind))" }
    }

    @Published private(set) var items: [Item] = []
    /// input yang sedang dipakai rute audio
    @Published private(set) var current = ""
    /// pilihan pengguna: "" = otomatis (yang terakhir dicolok)
    @Published var preferred: String = UserDefaults.standard.string(forKey: "audioInputUID") ?? "" {
        didSet {
            UserDefaults.standard.set(preferred, forKey: "audioInputUID")
            apply()
        }
    }

    private var obs: [NSObjectProtocol] = []
    private var configured = false

    private init() {
        let nc = NotificationCenter.default
        obs.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let r = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            // input pilihan dicolok lagi -> pasang lagi
            if r == .newDeviceAvailable, let self, !self.preferred.isEmpty { self.apply() } else { self?.refresh(reason: r) }
        })
    }

    static func kind(_ t: AVAudioSession.Port) -> String {
        switch t {
        case .builtInMic: return "Internal"
        case .usbAudio: return "USB"
        case .headsetMic: return "Kabel"
        case .bluetoothHFP: return "Bluetooth"
        case .lineIn: return "Line in"
        case .carAudio: return "Mobil"
        default: return t.rawValue
        }
    }

    /// pasang sesi audio untuk merekam video + input pilihan. Aman dipanggil berulang (antrean mana pun).
    func configure() {
        let s = AVAudioSession.sharedInstance()
        do {
            if !configured || s.category != .playAndRecord {
                try s.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetooth, .defaultToSpeaker])
            }
            try s.setActive(true)
            configured = true
        } catch {
            Log.camera.error("Mikrofon: sesi audio gagal diatur: \(error.localizedDescription, privacy: .public)")
        }
        DispatchQueue.main.async { self.apply() }
    }

    /// main
    func apply() {
        let s = AVAudioSession.sharedInstance()
        let ins = s.availableInputs ?? []
        let want = preferred.isEmpty ? nil : ins.first { $0.uid == preferred }
        do {
            try s.setPreferredInput(want)
        } catch {
            Log.camera.error("Mikrofon: gagal memilih input: \(error.localizedDescription, privacy: .public)")
        }
        refresh(reason: nil)
    }

    /// main
    func refresh(reason: AVAudioSession.RouteChangeReason?) {
        let s = AVAudioSession.sharedInstance()
        let ins = (s.availableInputs ?? []).map { Item(id: $0.uid, name: $0.portName, kind: Self.kind($0.portType)) }
        if ins != items { items = ins }
        let cur = s.currentRoute.inputs.first.map { "\($0.portName) (\(Self.kind($0.portType)))" } ?? "-"
        if cur != current {
            current = cur
            let list = ins.map(\.label).joined(separator: ", ")
            Log.camera.notice("Mikrofon: dipakai \(cur, privacy: .public); tersedia [\(list, privacy: .public)]; pilihan \(self.preferred.isEmpty ? "otomatis" : self.preferred, privacy: .public); alasan \(reason.map { String($0.rawValue) } ?? "-", privacy: .public)")
        }
        // input pilihan dicabut -> kembali otomatis (pilihan tetap disimpan, dipakai lagi saat dicolok)
    }
}
