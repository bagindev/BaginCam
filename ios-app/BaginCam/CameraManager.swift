import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// Semua akses AVCaptureSession / device dilakukan di `sessionQueue`.
/// Properti @Published hanya diubah di main thread.
/// Pemrosesan berat (HDR+, AI Zoom) di `processQueue`.
final class CameraManager: NSObject, ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case hdrplus = "HDR+"
        case bayer = "Bayer RAW"
        case proraw = "ProRAW"
        case heif = "HEIF"
        case aiZoom = "AI Zoom"
        var id: String { rawValue }
        var usesBayer: Bool { self == .bayer || self == .hdrplus }
        var isBurst: Bool { self != .aiZoom && self != .heif }
        var detail: String {
            switch self {
            case .hdrplus: return "Burst Bayer RAW (lensa otomatis / kunci) -> align + merge GPU, 1 suara shutter, bisa zoom"
            case .bayer: return "Burst Bayer RAW (untuk pc-lab)"
            case .proraw: return "Burst Apple ProRAW"
            case .heif: return "Seperti kamera bawaan: zoom 0.5-50x, lensa otomatis / kunci lensa"
            case .aiZoom: return "Zoom 1-25x, pilih lensa otomatis seperti kamera bawaan"
            }
        }
    }

    /// metode merge HDR+
    enum MergeMethod: String, CaseIterable, Identifiable {
        case frequency = "Frekuensi"
        case spatial = "Spasial"
        var id: String { rawValue }
    }

    /// preset white balance
    enum WBPreset: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case daylight = "Cerah"
        case cloudy = "Berawan"
        case shade = "Teduh"
        case tungsten = "Pijar"
        case fluorescent = "Neon"
        case locked = "Kunci"
        var id: String { rawValue }
        var kelvin: Float? {
            switch self {
            case .daylight: return 5500
            case .cloudy: return 6500
            case .shade: return 7500
            case .tungsten: return 3000
            case .fluorescent: return 4000
            default: return nil
            }
        }
    }

    /// mode di layar (niat memotret, seperti GCam). Mesin proses = `Mode` internal.
    enum ShootMode: String, CaseIterable, Identifiable {
        case night = "MALAM"
        case photo = "FOTO"
        case video = "VIDEO"
        case pro = "PRO"
        var id: String { rawValue }
    }

    /// proses di mode FOTO
    enum PhotoProcess: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case hdrplus = "HDR+"
        case apple = "Apple"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .auto: return "HDR+ saat gelap, Apple saat terang (instan) atau bila Live / flash aktif"
            case .hdrplus: return "Burst RAW 6-15 frame digabung BaginCam (noise rendah, highlight terjaga)"
            case .apple: return "1 jepretan Smart HDR / Deep Fusion Apple (instan, bisa Live & flash)"
            }
        }
    }

    /// cara memperbesar saat zoom MELEWATI lensa optik (di bawahnya = lensa optik apa adanya).
    /// AI (zoomAIEnabled) terpisah dan bisa ditumpuk di atas cara mana pun.
    enum ZoomMethod: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case apple = "Apple"
        case superRes = "Super Res"
        case fullCrop = "Crop penuh"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .auto: return "Super Res di tele atau crop >= 3x, Crop penuh di bawahnya (logika AI ZOOM lama)"
            case .apple: return "Zoom digital Apple seperti kamera bawaan (1 jepretan, Deep Fusion). + AI: diperkecil ke detail aslinya lalu diperbesar AI"
            case .superRes: return "Multi-frame: burst RAW lensa fisik digabung (HDR+), lalu crop & perbesar - noise rendah, detail asli"
            case .fullCrop: return "1 foto resolusi penuh sensor (48MP utama / 12MP tele) di-crop lalu diperbesar"
            }
        }
    }

    /// format di mode PRO
    enum ProFormat: String, CaseIterable, Identifiable {
        case hdrplus = "HDR+"
        case proraw = "ProRAW"
        case bayer = "Bayer"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .hdrplus: return "Manual + merge HDR+ (format HEIF/JPEG/DNG di Pengaturan)"
            case .proraw: return "Apple ProRAW DNG 12/24/48MP, pilih lensa fisik"
            case .bayer: return "Bayer RAW mentah per frame (DNG) untuk diproses di PC"
            }
        }
    }

    enum FlashSetting: String, CaseIterable, Identifiable {
        case off = "Mati"
        case auto = "Auto"
        case on = "Nyala"
        var id: String { rawValue }
        var avMode: AVCaptureDevice.FlashMode { self == .on ? .on : (self == .auto ? .auto : .off) }
        var icon: String { self == .on ? "bolt.fill" : (self == .auto ? "bolt.badge.automatic" : "bolt.slash") }
    }

    /// rencana capture mode MALAM (frame x shutter, ISO diturunkan supaya total eksposur sama)
    struct NightPlan {
        let frames: Int
        let shutter: Double
        let iso: Float
        var seconds: Double { Double(frames) * shutter }
    }

    /// `maxShutter`: genggam 1/4 s (tele 1/8 s), diam/tripod 1 s
    /// v0.10.0/0.10.1: crash saat app dibuka di MALAM - nilai live kamera belum valid (shutter NaN / 0)
    /// -> Int(NaN) trap. Semua masukan kini disaring dulu.
    static func nightPlan(iso: Float, shutter: Double, minISO: Float, steady: Bool, tele: Bool) -> NightPlan {
        let s0 = shutter.isFinite && shutter > 0 ? min(shutter, 1) : 1.0 / 30
        let i0 = iso.isFinite && iso > 0 ? iso : 400
        let mISO = minISO.isFinite && minISO > 0 ? minISO : 25
        let exposure = Double(i0) * s0
        let maxT = steady ? 1.0 : (tele ? 0.125 : 0.25)
        var t = max(s0, maxT)
        var i = Float(exposure / t)
        if i < mISO {
            i = mISO
            t = max(s0, exposure / Double(mISO))
        }
        if !t.isFinite || t <= 0 { t = maxT }
        let budget = steady ? 6.0 : 4.0          // detik total
        let n = budget / t
        let frames = n.isFinite ? min(15, max(6, Int(min(n, 100)))) : 6
        return NightPlan(frames: frames, shutter: t, iso: i.isFinite ? i : mISO)
    }

    enum Lens: String, CaseIterable, Identifiable {
        case ultraWide = "0.5x"
        case wide = "1x"
        case tele = "5x"
        case front = "Depan"
        var id: String { rawValue }
        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .ultraWide: return .builtInUltraWideCamera
            case .wide, .front: return .builtInWideAngleCamera
            case .tele: return .builtInTelephotoCamera
            }
        }
        var position: AVCaptureDevice.Position { self == .front ? .front : .back }
        var displayName: String {
            switch self {
            case .ultraWide: return "Ultra Wide"
            case .wide: return "Utama"
            case .tele: return "Tele"
            case .front: return "Depan"
            }
        }
    }

    // MARK: state untuk UI
    @Published var isAuto = true
    @Published var iso: Float = 400
    @Published var shutter: Double = 1.0 / 60     // detik
    @Published var temperature: Float = 5500
    @Published var lensPosition: Float = 0.5
    @Published private(set) var isoRange: ClosedRange<Float> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...0.5

    @Published private(set) var liveISO: Float = 0
    @Published private(set) var liveShutter: Double = 0
    @Published private(set) var liveTemp: Float = 0
    @Published private(set) var liveLens: Float = 0
    /// penanda lensa fisik yang sedang dipakai, mis. "Tele 5x" / "Utama · crop 7.0x"
    @Published private(set) var activeLensLabel = "Utama"

    @Published private(set) var mode: Mode = .hdrplus
    @Published private(set) var lens: Lens = .wide
    @Published private(set) var availableLenses: [Lens] = [.wide]
    // pengaturan disimpan (UserDefaults) - v0.9.5: tiap buka app kembali ke 12MP
    @Published var burstCount: Int = Prefs.get("burstCount", 8) { didSet { Prefs.set("burstCount", burstCount) } }
    @Published var outputMP: OutputMP = Prefs.raw("outputMP", .mp12) { didSet { Prefs.set("outputMP", outputMP.rawValue) } }  // resolusi output (HEIF, ProRAW, HDR+ HEIF/JPEG, AI Zoom)
    @Published var saveFrames: Bool = Prefs.get("saveFrames", false) { didSet { Prefs.set("saveFrames", saveFrames) } }  // HDR+: simpan juga frame mentah
    @Published var hdrNoiseReduction: Double = Prefs.get("hdrNoiseReduction", 18) { didSet { Prefs.set("hdrNoiseReduction", hdrNoiseReduction) } }  // HDR+: 1..23
    @Published var outputFormat: PhotoFormat = Prefs.raw("outputFormat", .heif) { didSet { Prefs.set("outputFormat", outputFormat.rawValue) } }  // format simpan HDR+
    @Published var bakeLUT: Bool = Prefs.get("bakeLUT", false) { didSet { Prefs.set("bakeLUT", bakeLUT) } }  // bakar LUT aktif ke HEIF/JPEG
    /// LUT yang sedang dipilih (di-set dari UI); dipakai bila bakeLUT aktif
    var captureLUT: CubeLUT?

    // AI Zoom
    @Published private(set) var totalZoom: CGFloat = 1 { didSet { if totalZoom != oldValue { updateZoomQuality() } } }  // relatif lensa utama (1x = 24mm)
    @Published private(set) var maxTotalZoom: CGFloat = 25
    @Published private(set) var autoLensAvailable = false     // kamera virtual (pilih lensa otomatis)
    /// zoom minimum mode Auto (0.5 bila ada ultra wide)
    @Published private(set) var minAutoZoom: CGFloat = 1

    /// mode yang memakai kamera virtual (lensa otomatis seperti kamera bawaan): AI ZOOM & FOTO
    static func usesVirtual(_ m: Mode) -> Bool { m == .aiZoom || m == .heif || m == .hdrplus }
    @Published var srModel: SRModel = Prefs.raw("srModel", .fast) { didSet { Prefs.set("srModel", srModel.rawValue) } }
    @Published var aiStrength: Double = Prefs.get("aiStrength", 0.5) { didSet { Prefs.set("aiStrength", aiStrength) } }  // 0 = pembesaran biasa, 1 = AI penuh
    @Published var textFocus: Bool = Prefs.get("textFocus", true) { didSet { Prefs.set("textFocus", textFocus) } }  // area tulisan: pilih AI/asli menurut OCR
    @Published var multiFrameZoom: Bool = Prefs.get("multiFrameZoom", true) { didSet { Prefs.set("multiFrameZoom", multiFrameZoom) } }  // burst Bayer + merge sebelum AI (bila tersedia)

    @Published private(set) var isCapturing = false
    /// progres pemrosesan berat (0..1), nil = tidak ada
    @Published private(set) var progress: Double?
    /// zoom di FOTO/HDR+: pakai AI (true) atau pembesaran biasa Lanczos (false) - untuk membandingkan
    @Published var zoomAIEnabled: Bool = Prefs.get("zoomAIEnabled", true) { didSet { Prefs.set("zoomAIEnabled", zoomAIEnabled) } }
    /// zoom preview tambahan di luar batas zoom hardware (dipakai renderer)
    @Published private(set) var previewExtraZoom: CGFloat = 1
    /// fokus/eksposur dikunci (tekan lama di preview)
    @Published private(set) var aeafLocked = false
    /// AI Zoom: kunci lensa fisik (nil = Auto, iOS memilih seperti kamera bawaan)
    @Published private(set) var aiLensLock: Lens?
    /// kompensasi eksposur (EV) saat mode Auto
    @Published private(set) var evBias: Float = 0
    @Published var mergeMethod: MergeMethod = Prefs.raw("mergeMethod", .frequency) { didSet { Prefs.set("mergeMethod", mergeMethod.rawValue) } }
    @Published var autoFrames: Bool = Prefs.get("autoFrames", true) { didSet { Prefs.set("autoFrames", autoFrames) } }  // HDR+: jumlah frame menurut kecerahan
    @Published private(set) var wbPreset: WBPreset = .auto
    @Published var timerSeconds: Int = Prefs.get("timerSeconds", 0) { didSet { Prefs.set("timerSeconds", timerSeconds) } }  // 0 / 3 / 10
    @Published private(set) var countdown = 0        // sisa hitungan timer (0 = tidak berjalan)
    /// preview dibekukan saat capture (zoom/lensa diganti di belakang layar)
    @Published private(set) var previewFrozen = false
    @Published private(set) var progressText = ""
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // susunan UI ala GCam (v0.10): MALAM · FOTO · PRO
    @Published private(set) var shootMode: ShootMode = Prefs.raw("shootMode", .photo) { didSet { Prefs.set("shootMode", shootMode.rawValue) } }
    @Published private(set) var photoProcess: PhotoProcess = Prefs.raw("photoProcess", .hdrplus) { didSet { Prefs.set("photoProcess", photoProcess.rawValue) } }
    @Published private(set) var proFormat: ProFormat = Prefs.raw("proFormat", .proraw) { didSet { Prefs.set("proFormat", proFormat.rawValue) } }
    @Published var aspect: AspectRatio = Prefs.raw("aspect", .r43) { didSet { Prefs.set("aspect", aspect.rawValue) } }
    @Published var flash: FlashSetting = Prefs.raw("flash", .off) { didSet { Prefs.set("flash", flash.rawValue) } }
    @Published private(set) var livePhoto: Bool = Prefs.get("livePhoto", false) { didSet { Prefs.set("livePhoto", livePhoto) } }
    @Published var zoomMethod: ZoomMethod = Prefs.raw("zoomMethod", .auto) { didSet { Prefs.set("zoomMethod", zoomMethod.rawValue) } }

    // MARK: video (ala Blackmagic Camera + GCam)
    @Published var videoRes: VideoRes = Prefs.raw("videoRes", .uhd) { didSet { Prefs.set("videoRes", videoRes.rawValue); videoChanged() } }
    @Published var videoFps: VideoFps = Prefs.raw("videoFps", .f30) { didSet { Prefs.set("videoFps", videoFps.rawValue); videoChanged() } }
    @Published var videoCodec: VideoCodec = Prefs.raw("videoCodec", .hevc) { didSet { Prefs.set("videoCodec", videoCodec.rawValue); videoChanged() } }
    @Published var videoColor: VideoColor = Prefs.raw("videoColor", .sdr) { didSet { Prefs.set("videoColor", videoColor.rawValue); videoChanged() } }
    @Published var videoStab: VideoStab = Prefs.raw("videoStab", .standard) { didSet { Prefs.set("videoStab", videoStab.rawValue); videoChanged() } }
    @Published var slowPlayback: Int = Prefs.get("slowPlayback", 30) { didSet { Prefs.set("slowPlayback", slowPlayback) } }
    @Published var timelapse: Int = Prefs.get("timelapse", 1) { didSet { Prefs.set("timelapse", timelapse); videoChanged() } }
    @Published var shutter180: Bool = Prefs.get("shutter180", true) { didSet { Prefs.set("shutter180", shutter180) } }
    @Published var videoSaveTo: VideoSaveTo = Prefs.raw("videoSaveTo", .photos) { didSet { Prefs.set("videoSaveTo", videoSaveTo.rawValue) } }
    @Published var bakeLUTVideo: Bool = Prefs.get("bakeLUTVideo", false) { didSet { Prefs.set("bakeLUTVideo", bakeLUTVideo) } }
    @Published var frameGuide: FrameGuide = Prefs.raw("frameGuide", .off) { didSet { Prefs.set("frameGuide", frameGuide.rawValue) } }
    @Published var torch = false { didSet { applyTorch() } }
    // v0.12: zoom video
    @Published var smoothZoom: SmoothZoom = Prefs.raw("smoothZoom", .medium) { didSet { Prefs.set("smoothZoom", smoothZoom.rawValue) } }
    @Published var sharpenZoom: Bool = Prefs.get("sharpenZoom", true) { didSet { Prefs.set("sharpenZoom", sharpenZoom); updateZoomQuality() } }
    @Published var lockLensOnRecord: Bool = Prefs.get("lockLensOnRecord2", false) { didSet { Prefs.set("lockLensOnRecord2", lockLensOnRecord) } }  // v0.12.4: bawaan mati (Auto tetap bisa pindah lensa saat rekam)
    /// titik zoom tanpa crop digital (relatif lensa utama), mis. [0.5, 1, 2, 5]
    @Published private(set) var nativeZoomPoints: [CGFloat] = []
    /// "Native" / "Digital 1.4x"
    @Published private(set) var zoomQuality = ""
    /// kekuatan penajaman zoom digital (preview + rekaman)
    @Published private(set) var previewSharpen: Float = 0
    /// 180° tidak tercapai karena terlalu terang (butuh filter ND)
    @Published private(set) var needND = false
    /// suhu HP (ProcessInfo.thermalState): 0 normal, 1 hangat, 2 panas, 3 kritis
    @Published private(set) var thermal = 0
    /// AI Upscale otomatis ditawarkan setelah rekam
    // v0.13: AI Komposisi (Susun ulang) + versi crop setelah jepret
    @Published var compAI: Bool = Prefs.get("compAI", true) { didSet { Prefs.set("compAI", compAI) } }
    @Published var compCrop: Bool = Prefs.get("compCrop", true) { didSet { Prefs.set("compCrop", compCrop) } }
    @Published var aiAfterRecord: Bool = Prefs.get("aiAfterRecord", false) { didSet { Prefs.set("aiAfterRecord", aiAfterRecord) } }
    /// video yang menunggu AI Upscale (dibuka otomatis setelah rekam)
    @Published var pendingUpscale: URL?
    private var autoLockedForRec = false        // main: lensa dikunci otomatis saat mulai rekam
    @Published private(set) var isRecording = false
    @Published private(set) var recordSeconds: Double = 0
    @Published private(set) var audioLevel: Float = -160        // dB (meter)
    @Published private(set) var videoInfo = ""                   // mis. "4K · 30 · HEVC · Log"
    @Published private(set) var minutesLeft = 0
    @Published private(set) var horizonAngle: CGFloat = 90       // 0/180 = HP lanskap
    private var recordStart = Date()
    private var recordTimer: Timer?
    private var readoutTick = 0
    @Published private(set) var flashAvailable = false
    @Published private(set) var liveAvailable = false
    /// iOS memakai ultra wide untuk objek dekat (makro) padahal zoom >= 1x
    @Published private(set) var macroActive = false
    /// teks di preview saat capture (mis. "MALAM: tahan HP ~3 s")
    @Published private(set) var captureHint = ""
    /// HP diam (dari LevelMonitor) - dipakai mode MALAM
    var deviceSteady = false
    /// putaran gyro saat ini (rad/s), untuk log MALAM
    var motionLevel: (() -> Double)?
    // kontrol manual per bagian (laci Pro): eksposur / WB / fokus
    @Published private(set) var manualExposure = false
    @Published private(set) var manualWB = false
    @Published private(set) var manualFocus = false
    // foto terakhir (thumbnail + penampil)
    @Published private(set) var lastThumb: UIImage?
    private(set) var lastImageData: Data?
    @Published private(set) var lastFileName = ""
    @Published private(set) var status = "Menyiapkan kamera..."
    @Published private(set) var supportsBayer = false
    @Published private(set) var supportsProRAW = false
    @Published private(set) var maxMP = 12
    let srFastAvailable = SRUpscaler.isBundled(.fast)
    let srDetailAvailable = SRUpscaler.isBundled(.detail)

    /// Dipanggil di antrean video untuk tiap frame preview.
    var onFrame: ((CIImage) -> Void)?

    // MARK: AVFoundation
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "bagincam.session")
    private let videoQueue = DispatchQueue(label: "bagincam.video", qos: .userInteractive)
    private let processQueue = DispatchQueue(label: "bagincam.process", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var inVideo = false                 // sessionQueue
    private var fpsApplied = 30                 // sessionQueue
    private var shutter180Warned = false        // sessionQueue
    private var recSharpen: Float = 0           // videoQueue
    private var ndWarned = false                // sessionQueue
    private var videoSnap = VideoSnap()         // sessionQueue: pengaturan video terakhir
    private var recorder: VideoRecorder?        // videoQueue
    private var previewLog = false              // videoQueue: preview Apple Log -> Rec.709
    private lazy var logPreviewFilter = AppleLogLUT.makeFilter()   // videoQueue
    private var device: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var readoutTimer: Timer?
    private var configured = false

    // kamera virtual (AI Zoom)
    private var isVirtual = false
    private var wideBase: CGFloat = 1                                  // videoZoomFactor = 1x lensa utama
    private var lensBase: [AVCaptureDevice.DeviceType: CGFloat] = [:]  // zoom factor native tiap lensa
    private var lensBaseMain: [AVCaptureDevice.DeviceType: CGFloat] = [:]  // salinan untuk main thread

    // burst (diakses di sessionQueue)
    private var burstRemaining = 0
    private var burstIndex = 0
    private var burstAuto = true
    private var burstMode: Mode = .hdrplus
    private var burstDir: URL?
    private var burstSaveFrames = false
    private var burstNR: Double = 18
    private var burstOutputMP: OutputMP = .mp12
    private var burstFormat: PhotoFormat = .heif
    private var burstLUT: CubeLUT?
    private var burstTotalZoom: CGFloat = 1
    private var burstCrop: CGFloat = 1            // crop digital di atas lensa native
    private var burstZoomed = false               // capture ini di-crop + upscale (AI Zoom / zoom FOTO-HDR+)
    private var burstDisplayZoom: CGFloat = 1     // zoom total untuk nama file / status
    private var subjectObserver: NSObjectProtocol?
    private var aiLockNative: CGFloat = 0           // sessionQueue: faktor optik lensa terkunci (0 = tidak dikunci)
    private var evBiasSession: Float = 0
    private var wbPresetSession: WBPreset = .auto
    private var burstMerge: MergeMethod = .frequency
    private var burstLensName = "Utama"
    private var burstAIFull = false               // AI Zoom: minta resolusi penuh
    private var burstAIMultiFrame = false
    private var burstSRModel: SRModel = .fast
    private var burstStrength: Double = 0.5
    private var burstTextFocus = true
    private var burstAppleZoomAI = false          // zoom Apple + AI: perkecil ke detail asli lalu AI
    private var burstRealLong = 4032              // sisi panjang detail asli pada zoom Apple
    private var burstNight = false
    private var burstAspect: AspectRatio = .r43
    private var burstFlash: FlashSetting = .off
    private var burstLive = false
    private var livePending: (data: Data, name: String)?
    private var liveMovieURL: URL?
    private var restoreZoomAfterBurst = false
    private var switchedToPhysicalForMF = false   // AI Zoom MF: sementara pakai lensa fisik (Bayer)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var savedCount = 0
    private var hdrFrames: [BayerFrame] = []
    private var hdrRef: AVCapturePhoto?

    // engine
    private var merger: HDRPlusMerger?                 // sessionQueue
    private var upscalers: [SRModel: SRUpscaler] = [:] // processQueue
    private var upscalerFailed: Set<SRModel> = []      // processQueue

    // MARK: lifecycle
    /// Panggil dari main thread.
    func start() {
        if !configured { self.mode = Self.internalMode(shootMode, photoProcess, proFormat) }
        let mode = self.mode, lens = self.lens
        let live = liveWanted
        sessionQueue.async { self.liveWantedS = live }
        let video = shootMode == .video
        if video { AVCaptureDevice.requestAccess(for: .audio) { _ in }; videoSnap = makeVideoSnap() }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { self.setStatus("Izin kamera ditolak"); return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
            self.sessionQueue.async {
                if !self.configured { self.configure(mode: mode, lens: lens) }
                if video { self.enterVideo() }
                if !self.session.isRunning { self.session.startRunning() }
                self.setStatus("Siap")
            }
        }
        readoutTimer?.invalidate()
        readoutTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateReadout()
        }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
        readoutTimer?.invalidate()
    }

    private func configure(mode: Mode, lens: Lens) {
        configured = true
        subjectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                                                                 object: nil, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { self?.resetFocusToCenter() }
        }
        merger = HDRPlusMerger()
        if merger == nil { Log.hdr.error("HDRPlusMerger tidak tersedia (Metal)") }

        session.beginConfiguration()
        session.sessionPreset = .photo
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        let lenses = Lens.allCases.filter { AVCaptureDevice.default($0.deviceType, for: .video, position: $0.position) != nil }
        let virtual = Self.virtualDevice() != nil
        DispatchQueue.main.async {
            self.availableLenses = lenses
            self.autoLensAvailable = virtual
        }
        // v0.10.0: hanya .aiZoom -> HDR+/FOTO dibuka di lensa utama FISIK (zoom 13x = crop utama, buram)
        if Self.usesVirtual(mode) { enterAIZoom() } else {
            switchDevice(to: lenses.contains(lens) ? lens : (lenses.first ?? .wide), mode: mode)
        }
    }

    // MARK: lensa fisik
    func setLens(_ l: Lens) {
        guard !isCapturing, l != lens || mode == .aiZoom else { return }
        lens = l
        isAuto = true
        let m = mode
        sessionQueue.async { self.switchDevice(to: l, mode: m) }
    }

    private func switchDevice(to l: Lens, mode: Mode) {
        guard let d = AVCaptureDevice.default(l.deviceType, for: .video, position: l.position) else {
            setStatus("Lensa \(l.rawValue) tidak tersedia")
            return
        }
        isVirtual = false
        aiLockNative = 0
        install(d, mirrored: l == .front)
        applyRawMode(mode)
        applyAuto()
        let maxDigital: CGFloat = l == .wide ? 50 : 10   // total maks 50x (utama) / 50x (tele 5x x10)
        DispatchQueue.main.async {
            self.totalZoom = 1
            self.maxTotalZoom = maxDigital
            self.previewExtraZoom = 1
            self.aeafLocked = false
        }
        publishCapabilities(d, label: l.displayName, mode: mode)
    }

    /// Pasang device ke session (fisik atau virtual).
    private func install(_ d: AVCaptureDevice, mirrored: Bool) {
        guard let input = try? AVCaptureDeviceInput(device: d) else { return }
        session.beginConfiguration()
        if let cur = currentInput { session.removeInput(cur) }
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            device = d
        } else if let cur = currentInput, session.canAddInput(cur) {
            session.addInput(cur)
        }
        for conn in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            guard let c = conn else { continue }
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = mirrored
            }
        }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil)
        if session.outputs.contains(photoOutput) {
            if let maxDims = maxDimensions(of: d) { photoOutput.maxPhotoDimensions = maxDims }
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        session.commitConfiguration()
        applyLive()
        let flashOK = photoOutput.supportedFlashModes.contains(.on)
        let liveOK = photoOutput.isLivePhotoCaptureSupported
        DispatchQueue.main.async {
            self.flashAvailable = flashOK
            self.liveAvailable = liveOK
        }
    }

    // MARK: kamera virtual (AI Zoom)
    private static func virtualDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
    }

    /// AI Zoom memakai kamera virtual Apple: iOS sendiri memilih lensa (tele vs crop lensa utama)
    /// berdasarkan zoom, jarak fokus minimum tele, dan cahaya - sama seperti kamera bawaan.
    private func enterAIZoom(zoom startZoom: CGFloat = 1) {
        guard let vd = Self.virtualDevice() else {
            // tidak ada kamera virtual -> lensa utama + zoom digital
            switchDevice(to: .wide, mode: .aiZoom)
            return
        }
        install(vd, mirrored: false)
        isVirtual = true
        aiLockNative = 0
        let cons = vd.constituentDevices
        let sw = vd.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        var bases: [AVCaptureDevice.DeviceType: CGFloat] = [:]
        for (i, c) in cons.enumerated() { bases[c.deviceType] = i == 0 ? 1 : (i - 1 < sw.count ? sw[i - 1] : 1) }
        lensBase = bases
        wideBase = bases[.builtInWideAngleCamera] ?? 1
        let maxZ: CGFloat = 50   // di atas batas hardware: preview di-crop tambahan, capture tetap crop sendiri
        if (try? vd.lockForConfiguration()) != nil {
            vd.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            vd.videoZoomFactor = min(max(startZoom * wideBase, vd.minAvailableVideoZoomFactor), vd.maxAvailableVideoZoomFactor)
            vd.unlockForConfiguration()
        }
        applyRawMode(.aiZoom)
        applyAuto()
        let baseText = cons.map { "\($0.localizedName)=\(bases[$0.deviceType] ?? 0)" }.joined(separator: ", ")
        Log.camera.info("Kamera virtual \(vd.localizedName, privacy: .public): \(baseText, privacy: .public), maks zoom \(Double(maxZ), privacy: .public)x")
        DispatchQueue.main.async {
            self.lensBaseMain = bases
            self.minAutoZoom = bases[.builtInUltraWideCamera] != nil ? 1 / max(bases[.builtInWideAngleCamera] ?? 1, 1) : 1
            self.maxTotalZoom = maxZ
            self.totalZoom = min(max(1, startZoom), maxZ)
        }
        publishCapabilities(vd, label: "Auto", mode: .aiZoom)
        if inVideo { applyVideoFormat() }
    }

    /// AI Zoom: kunci ke lensa fisik (Utama / Tele) atau Auto (nil). Panggil dari main thread.
    func setAILensLock(_ l: Lens?) {
        guard Self.usesVirtual(mode), !isCapturing, !isRecording, l != aiLensLock else { return }
        aiLensLock = l
        aeafLocked = false
        let native: CGFloat = l == .tele ? 5 : (l == .ultraWide ? 0.5 : 1)
        let tz = max(totalZoom, l == nil ? 1 : native)
        sessionQueue.async {
            guard let l else {
                self.enterAIZoom(zoom: tz)
                if self.inVideo { self.applyVideoFormat() }   // v0.12: dulu format video hilang setelah kembali ke Auto
                return
            }
            guard let d = AVCaptureDevice.default(l.deviceType, for: .video, position: l.position) else {
                self.setStatus("Lensa \(l.displayName) tidak tersedia")
                return
            }
            self.isVirtual = false
            self.install(d, mirrored: l == .front)
            self.aiLockNative = native
            self.applyRawMode(.aiZoom)
            self.applyAuto()
            if (try? d.lockForConfiguration()) != nil {
                d.videoZoomFactor = min(max(tz / native, 1), d.maxAvailableVideoZoomFactor)
                d.unlockForConfiguration()
            }
            Log.camera.info("AI Zoom: lensa dikunci ke \(l.displayName, privacy: .public)")
            DispatchQueue.main.async {
                self.maxTotalZoom = 50
                self.totalZoom = tz
                self.previewExtraZoom = max(1, (tz / native) / max(d.maxAvailableVideoZoomFactor, 1))
            }
            self.publishCapabilities(d, label: l.displayName, mode: .aiZoom)
            if self.inVideo { self.applyVideoFormat() }
        }
    }

    /// Preset white balance (Auto / Kelvin tetap / Kunci WB saat ini). Panggil dari main thread.
    func setWBPreset(_ p: WBPreset) {
        wbPreset = p
        sessionQueue.async {
            self.wbPresetSession = p
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            self.applyWB(d)
            d.unlockForConfiguration()
        }
        if manualWB {           // preset menggantikan WB manual (Kelvin) dari laci Pro
            manualWB = false
            isAuto = !(manualExposure || manualFocus)
            applyManual()
        }
    }

    /// dipanggil di sessionQueue dengan device sudah di-lock
    private func applyWB(_ d: AVCaptureDevice) {
        switch wbPresetSession {
        case .auto:
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        case .locked:
            if d.isWhiteBalanceModeSupported(.locked) {
                d.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
            }
        default:
            if let k = wbPresetSession.kelvin, d.isWhiteBalanceModeSupported(.locked), d.maxWhiteBalanceGain >= 1 {
                let tv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: k, tint: 0)
                d.setWhiteBalanceModeLocked(with: Self.clamp(d.deviceWhiteBalanceGains(for: tv), d.maxWhiteBalanceGain),
                                            completionHandler: nil)
            }
        }
    }

    /// Kompensasi eksposur (-3..+3 EV) untuk mode Auto. Panggil dari main thread.
    func setEVBias(_ v: Float) {
        evBias = v
        sessionQueue.async {
            self.evBiasSession = v
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.setExposureTargetBias(min(max(v, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
            d.unlockForConfiguration()
        }
    }

    /// Zoom total (1x = lensa utama). Panggil dari main thread.
    func setTotalZoom(_ z: CGFloat) {
        var minZ: CGFloat = 1
        if Self.usesVirtual(mode) {
            switch aiLensLock {
            case .tele?: minZ = 5
            case .ultraWide?: minZ = 0.5
            case nil: minZ = minAutoZoom
            default: minZ = 1
            }
        }
        var zz = min(max(minZ, z), maxTotalZoom)
        let video = shootMode == .video
        // v0.12: video menempel ke titik native (tanpa crop digital) bila dekat (<3 %)
        if video, let p = nativeZoomPoints.first(where: { abs($0 - zz) / $0 < 0.03 }) { zz = p }
        totalZoom = zz
        let rate = video ? smoothZoom.rate : 0
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            let base = self.isVirtual ? self.wideBase : (self.aiLockNative > 0 ? 1 / self.aiLockNative : 1)
            let want = zz * base
            let applied = min(max(want, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            if self.inVideo && rate > 0 {
                d.ramp(toVideoZoomFactor: applied, withRate: rate)     // zoom halus ala Blackmagic
            } else {
                d.videoZoomFactor = applied
            }
            d.unlockForConfiguration()
            if self.inVideo {
                // video: crop preview di atas batas hardware tidak ikut terekam -> zoom dibatasi hardware
                DispatchQueue.main.async {
                    self.previewExtraZoom = 1
                    if want > applied * 1.001 { self.totalZoom = applied / base }
                }
                return
            }
            let extra = max(1, want / applied)
            DispatchQueue.main.async { self.previewExtraZoom = extra }
        }
    }

    // MARK: sentuh untuk fokus
    /// `p`: titik di preview potret, 0..1. Tekan lama (`lock`) = kunci AE/AF di titik itu.
    func focus(atViewPoint p: CGPoint, lock: Bool) {
        guard !(manualExposure && manualFocus), !isCapturing else { return }
        let mExp = manualExposure, mFocus = manualFocus
        let front = lens == .front && mode != .aiZoom
        let extra = previewExtraZoom
        aeafLocked = false
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            // potret (rotasi 90): x sensor = y layar, y sensor = 1 - x layar (depan dicerminkan: = x layar)
            var x = Double(p.y), y = front ? Double(p.x) : 1 - Double(p.x)
            let z = Double(d.videoZoomFactor / max(d.minAvailableVideoZoomFactor, 1) * extra)
            x = 0.5 + (x - 0.5) / z
            y = 0.5 + (y - 0.5) / z
            let pt = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            if !mFocus, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = pt
                d.focusMode = .autoFocus
            }
            if !mExp, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = pt
                d.exposureMode = .continuousAutoExposure
            }
            d.isSubjectAreaChangeMonitoringEnabled = !lock
            d.unlockForConfiguration()
            Log.camera.info("Fokus di layar (\(Double(p.x), privacy: .public), \(Double(p.y), privacy: .public)) -> sensor (\(pt.x, privacy: .public), \(pt.y, privacy: .public)), kunci \(lock, privacy: .public)")
            if lock {
                self.sessionQueue.asyncAfter(deadline: .now() + 0.8) {
                    guard let d2 = self.device, d2 === d, (try? d2.lockForConfiguration()) != nil else { return }
                    if d2.isFocusModeSupported(.locked) { d2.focusMode = .locked }
                    if d2.isExposureModeSupported(.locked) { d2.exposureMode = .locked }
                    d2.unlockForConfiguration()
                    DispatchQueue.main.async { self.aeafLocked = true }
                }
            }
        }
    }

    /// subjek berubah -> kembali ke fokus/eksposur otomatis di tengah (kecuali sedang dikunci)
    private func resetFocusToCenter() {
        guard !aeafLockedSnapshot, let d = device, (try? d.lockForConfiguration()) != nil else { return }
        let c = CGPoint(x: 0.5, y: 0.5)
        if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = c }
        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = c }
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        d.isSubjectAreaChangeMonitoringEnabled = false
        d.unlockForConfiguration()
    }

    private var aeafLockedSnapshot: Bool {
        var v = false
        DispatchQueue.main.sync { v = self.aeafLocked }
        return v
    }

    private func maxDimensions(of d: AVCaptureDevice) -> CMVideoDimensions? {
        d.activeFormat.supportedMaxPhotoDimensions.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
    }

    /// Dimensi ~12MP (untuk Bayer RAW & foto standar).
    private func standardDimensions(of d: AVCaptureDevice) -> CMVideoDimensions? {
        d.activeFormat.supportedMaxPhotoDimensions.min {
            abs(Int($0.width) * Int($0.height) - 12_000_000) < abs(Int($1.width) * Int($1.height) - 12_000_000)
        }
    }

    private func publishCapabilities(_ d: AVCaptureDevice, label: String, mode: Mode) {
        let fmt = d.activeFormat
        let minS = max(fmt.minExposureDuration.seconds, 1.0 / 8000)
        let maxS = max(min(fmt.maxExposureDuration.seconds, 1.0), minS * 2)
        let bayer = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
            || photoOutput.isAppleProRAWEnabled   // saat ProRAW aktif, daftar Bayer disembunyikan
        let pro = photoOutput.isAppleProRAWSupported
        let mp = maxDimensions(of: d).map { Int($0.width) * Int($0.height) / 1_000_000 } ?? 12
        Log.camera.info("Lensa \(label, privacy: .public): ISO \(fmt.minISO, privacy: .public)-\(fmt.maxISO, privacy: .public), shutter \(minS, privacy: .public)-\(maxS, privacy: .public)s, Bayer \(bayer, privacy: .public), ProRAW \(pro, privacy: .public), maks \(mp, privacy: .public)MP")
        DispatchQueue.main.async {
            self.isoRange = fmt.minISO...fmt.maxISO
            self.shutterRange = minS...maxS
            self.supportsBayer = bayer
            self.supportsProRAW = pro
            self.maxMP = mp
            if (mode.usesBayer && !bayer) || (mode == .proraw && !pro) {
                self.setMode(.heif)
                self.status = "Lensa \(label) tidak mendukung \(mode.rawValue) -> HEIF"
            }
        }
    }

    // MARK: mode
    func setMode(_ m: Mode) {
        guard !isCapturing, m != mode else { return }
        let old = mode
        mode = m
        let l = lens
        sessionQueue.async {
            if Self.usesVirtual(m) {
                if !Self.usesVirtual(old) {
                    DispatchQueue.main.async { self.aiLensLock = nil }
                    self.enterAIZoom()
                } else {
                    self.applyRawMode(m)       // AI ZOOM <-> FOTO: device & kunci lensa tetap
                }
            } else if Self.usesVirtual(old) {
                self.switchDevice(to: l, mode: m)
            } else {
                self.applyRawMode(m)
            }
        }
    }

    // MARK: mode UI (MALAM · FOTO · PRO)
    static func internalMode(_ s: ShootMode, _ p: PhotoProcess, _ f: ProFormat) -> Mode {
        switch s {
        case .night: return .hdrplus
        case .photo: return p == .apple ? .heif : .hdrplus
        case .video: return .heif          // kamera virtual; sesi video diatur enterVideo()
        case .pro: return f == .proraw ? .proraw : (f == .bayer ? .bayer : .hdrplus)
        }
    }

    /// Live tersedia di FOTO apa pun prosesnya; saat Live/flash nyala, jepretan memakai proses Apple
    /// (v0.10.0: tombol Live disembunyikan saat proses HDR+ -> pengguna mengira Live tidak ada)
    private var liveWanted: Bool { livePhoto && shootMode == .photo }

    /// ganti mode/proses/format; Live dimatikan SEBELUM ganti mesin (ProRAW/Bayer), dinyalakan sesudahnya
    private func applyUI(_ change: () -> Void) {
        guard !isCapturing, !isRecording else { return }
        let wasVideo = shootMode == .video
        change()
        let isVideo = shootMode == .video
        if wasVideo && !isVideo {
            torch = false
            sessionQueue.async { self.leaveVideo() }      // sebelum mesin foto dipasang lagi
        }
        let want = liveWanted
        if !want { applyLiveSoon(want) }
        setMode(Self.internalMode(shootMode, photoProcess, proFormat))
        if want { applyLiveSoon(want) }
        if isVideo && !wasVideo { beginVideo() }
    }

    func setShootMode(_ s: ShootMode) { applyUI { shootMode = s } }
    func setPhotoProcess(_ p: PhotoProcess) { applyUI { photoProcess = p } }
    func setProFormat(_ f: ProFormat) { applyUI { proFormat = f } }
    func setLivePhoto(_ on: Bool) {
        applyUI { livePhoto = on }
        if on && photoProcess == .hdrplus { status = "Live nyala: foto (tanpa zoom digital) memakai proses Apple, karena HDR+ tidak punya video Live" }
    }

    private var liveWantedS = false      // sessionQueue
    private var liveSuspended = false    // sessionQueue: dimatikan sementara selama capture lensa fisik

    private func applyLiveSoon(_ want: Bool) {
        sessionQueue.async {
            self.liveWantedS = want
            self.applyLive()
        }
    }

    /// sessionQueue
    private func applyLive() {
        let w = liveWantedS && !liveSuspended && photoOutput.isLivePhotoCaptureSupported
        guard photoOutput.isLivePhotoCaptureEnabled != w else { return }
        session.beginConfiguration()
        photoOutput.isLivePhotoCaptureEnabled = w
        session.commitConfiguration()
        Log.camera.info("Live Photo enabled = \(w, privacy: .public)")
    }

    /// ProRAW harus di-enable di photo output sebelum dipakai; Bayer RAW butuh ProRAW off.
    private func applyRawMode(_ m: Mode) {
        let wantPro = m == .proraw && photoOutput.isAppleProRAWSupported
        guard photoOutput.isAppleProRAWEnabled != wantPro else { return }
        session.beginConfiguration()
        photoOutput.isAppleProRAWEnabled = wantPro
        session.commitConfiguration()
        Log.camera.info("ProRAW enabled = \(wantPro, privacy: .public)")
    }

    // MARK: exposure / WB / fokus
    /// semua auto (true) / semua manual mulai dari nilai live (false)
    func setAuto(_ auto: Bool) {
        setManual(exposure: !auto, wb: !auto, focus: !auto)
    }

    /// kontrol manual per bagian (laci Pro). nil = tidak diubah. Panggil dari main thread.
    func setManual(exposure: Bool? = nil, wb: Bool? = nil, focus: Bool? = nil) {
        if let e = exposure {
            if e && !manualExposure {
                iso = liveISO > 0 ? liveISO : iso
                shutter = liveShutter > 0 ? liveShutter : shutter
            }
            manualExposure = e
        }
        if let w = wb {
            if w && !manualWB { temperature = liveTemp > 0 ? liveTemp : temperature }
            manualWB = w
            if w {
                wbPreset = .auto
                sessionQueue.async { self.wbPresetSession = .auto }
            }
        }
        if let f = focus {
            if f && !manualFocus { lensPosition = liveLens }
            manualFocus = f
        }
        isAuto = !(manualExposure || manualWB || manualFocus)
        applyManual()
    }

    private struct ManualState {
        var exposure = false, wb = false, focus = false
        var iso: Float = 400, shutter: Double = 1.0 / 60, temp: Float = 5500, lens: Float = 0.5
    }
    private var manualS = ManualState()   // sessionQueue

    /// semua bagian sesuai status auto/manual (setelah ganti lensa / selesai burst). sessionQueue.
    private func applyAuto() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        applyParts(d, manualS, all: true, prev: manualS)
        d.unlockForConfiguration()
    }

    /// device sudah di-lock. `all` = terapkan semua bagian; selain itu hanya yang manual / baru kembali ke auto
    private func applyParts(_ d: AVCaptureDevice, _ m: ManualState, all: Bool, prev: ManualState) {
        let fmt = d.activeFormat
        if m.exposure {
            if d.isExposureModeSupported(.custom) {
                let s = min(max(m.shutter, fmt.minExposureDuration.seconds), fmt.maxExposureDuration.seconds)
                d.setExposureModeCustom(duration: CMTime(seconds: s, preferredTimescale: 1_000_000_000),
                                        iso: min(max(m.iso, fmt.minISO), fmt.maxISO), completionHandler: nil)
            }
        } else if all || prev.exposure {
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            d.setExposureTargetBias(min(max(evBiasSession, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
        }
        if m.wb {
            if d.isWhiteBalanceModeSupported(.locked), d.maxWhiteBalanceGain >= 1 {
                let tv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: min(max(m.temp, 2500), 9000), tint: 0)
                d.setWhiteBalanceModeLocked(with: Self.clamp(d.deviceWhiteBalanceGains(for: tv), d.maxWhiteBalanceGain),
                                            completionHandler: nil)
            }
        } else if all || prev.wb {
            applyWB(d)
        }
        if m.focus {
            if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: min(max(m.lens, 0), 1), completionHandler: nil)
            }
        } else if all || prev.focus {
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        }
    }

    /// Kirim nilai manual ke kamera.
    func applyManual() {
        let st = ManualState(exposure: manualExposure, wb: manualWB, focus: manualFocus,
                             iso: iso, shutter: shutter, temp: temperature, lens: lensPosition)
        sessionQueue.async {
            let prev = self.manualS
            self.manualS = st
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            self.applyParts(d, st, all: false, prev: prev)
            d.unlockForConfiguration()
        }
    }

    private static func clamp(_ g: AVCaptureDevice.WhiteBalanceGains, _ maxGain: Float) -> AVCaptureDevice.WhiteBalanceGains {
        var g = g
        g.redGain = min(max(g.redGain, 1), maxGain)
        g.greenGain = min(max(g.greenGain, 1), maxGain)
        g.blueGain = min(max(g.blueGain, 1), maxGain)
        return g
    }

    /// Kunci AE/AWB/AF di nilai saat ini (untuk burst di mode auto).
    private func lockCurrent() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
        if wbPresetSession == .auto, d.isWhiteBalanceModeSupported(.locked) {
            d.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
        }
        if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
        d.unlockForConfiguration()
    }

    /// Baca nilai kamera untuk ditampilkan (main thread).
    /// PENTING: API white balance AVFoundation melempar NSException (crash, tidak bisa di-catch Swift)
    /// bila gain di luar [1, maxWhiteBalanceGain] - mis. gain 0 sebelum session jalan (bug v0.1.0).
    private func updateReadout() {
        guard let d = device, session.isRunning else { return }
        // nilai bisa NaN sebelum kamera stabil -> UI memakai Int(...) (crash v0.10.0)
        liveISO = d.iso.isFinite ? d.iso : 0
        let s = d.exposureDuration.seconds
        liveShutter = s.isFinite ? s : 0
        liveLens = d.lensPosition.isFinite ? d.lensPosition : 0
        activeLensLabel = lensLabel(for: d)
        let macro = d.isVirtualDevice && d.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera && totalZoom >= 0.95
        if macro != macroActive { macroActive = macro }
        if let rc = rotationCoordinator {
            let a = rc.videoRotationAngleForHorizonLevelCapture
            if a != horizonAngle { horizonAngle = a }
        }
        if shootMode == .video { videoReadout() }
        let maxGain = d.maxWhiteBalanceGain
        let g = d.deviceWhiteBalanceGains
        guard maxGain >= 1, g.redGain > 0, g.greenGain > 0, g.blueGain > 0 else { return }
        let temp = d.temperatureAndTintValues(for: Self.clamp(g, maxGain)).temperature
        if temp.isFinite { liveTemp = temp }
    }

    private static func name(of type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInTelephotoCamera: return "Tele"
        case .builtInUltraWideCamera: return "Ultra Wide"
        default: return "Utama"
        }
    }

    /// "Tele 5x", "Utama · crop 7.0x", "Ultra Wide 0.5x", ...
    private func lensLabel(for d: AVCaptureDevice) -> String {
        let z = d.videoZoomFactor
        if d.isVirtualDevice, let p = d.activePrimaryConstituent {
            let base = lensBaseMain[p.deviceType] ?? 1
            let wide = lensBaseMain[.builtInWideAngleCamera] ?? 1
            let native = base / wide                    // 0.5x / 1x / 5x relatif lensa utama
            let crop = z / base
            let n = Self.name(of: p.deviceType)
            let nat = native < 1 ? String(format: "%.1fx", Double(native)) : String(format: "%.0fx", Double(native))
            return crop > 1.05 ? String(format: "%@ %@ · crop %.1fx", n, nat, Double(crop)) : "\(n) \(nat)"
        }
        let l = (Self.usesVirtual(mode) ? aiLensLock : nil) ?? lens
        let n = l.displayName + (Self.usesVirtual(mode) && aiLensLock != nil ? " (kunci)" : "")
        return z > 1.05 ? String(format: "%@ · crop %.1fx", n, Double(z)) : (l == .front ? n : "\(n) \(l.rawValue)")
    }

    // MARK: video
    struct VideoSnap {
        var res: VideoRes = .uhd
        var fps: VideoFps = .f30
        var codec: VideoCodec = .hevc
        var color: VideoColor = .sdr
        var stab: VideoStab = .standard
        var timelapse = 1
        var zoom: CGFloat = 1
    }

    private func makeVideoSnap() -> VideoSnap {
        VideoSnap(res: videoRes, fps: videoFps, codec: videoCodec, color: videoColor, stab: videoStab,
                  timelapse: timelapse, zoom: totalZoom)
    }

    /// pengaturan video berubah -> format kamera diatur ulang (tidak saat merekam)
    private func videoChanged() {
        guard shootMode == .video, !isRecording else { return }
        let snap = makeVideoSnap()
        sessionQueue.async {
            self.videoSnap = snap
            self.applyVideoFormat()
        }
    }

    /// main: masuk mode VIDEO (izin mikrofon dulu)
    private func beginVideo() {
        let snap = makeVideoSnap()
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            self.sessionQueue.async {
                self.videoSnap = snap
                self.enterVideo()
            }
        }
    }

    /// sessionQueue: photo output dilepas (format video bebas), mikrofon dipasang
    private func enterVideo() {
        guard !inVideo else { applyVideoFormat(); return }
        inVideo = true
        shutter180Warned = false
        session.beginConfiguration()
        if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio), let inp = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(inp) {
            session.addInput(inp)
            audioInput = inp
        }
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
        }
        session.commitConfiguration()
        Log.camera.info("VIDEO: masuk, mikrofon \(self.audioInput != nil, privacy: .public)")
        applyVideoFormat()
    }

    /// sessionQueue: kembali ke sesi foto
    private func leaveVideo() {
        guard inVideo else { return }
        inVideo = false
        session.beginConfiguration()
        if let a = audioInput { session.removeInput(a); audioInput = nil }
        if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.automaticallyConfiguresCaptureDeviceForWideColor = true
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        if let c = videoOutput.connection(with: .video), c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
        session.commitConfiguration()
        if let d = device {
            if session.outputs.contains(photoOutput), let maxDims = maxDimensions(of: d) { photoOutput.maxPhotoDimensions = maxDims }
            applyAuto()
        }
        videoQueue.async { self.previewLog = false }
        Log.camera.info("VIDEO: keluar")
        DispatchQueue.main.async { self.videoInfo = ""; self.nativeZoomPoints = []; self.updateZoomQuality() }
    }

    private static let tenBitFmt: FourCharCode = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    /// sessionQueue: titik zoom native (lensa fisik + crop sensor 48 MP "kualitas optik") untuk format video aktif
    private func updateNativePoints(_ d: AVCaptureDevice) {
        var pts: [CGFloat] = []
        let fmt = d.activeFormat
        let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        func secondary(of c: AVCaptureDevice) -> [CGFloat] {
            let m = c.formats.first { g in
                let x = CMVideoFormatDescriptionGetDimensions(g.formatDescription)
                return x.width == dim.width && x.height == dim.height && Self.supportsFps(g, fpsApplied)
                    && !g.secondaryNativeResolutionZoomFactors.isEmpty
            }
            return m?.secondaryNativeResolutionZoomFactors ?? []
        }
        if d.isVirtualDevice {
            for c in d.constituentDevices {
                let b = (lensBase[c.deviceType] ?? 1) / max(wideBase, 0.01)
                pts.append(b)
                pts += secondary(of: c).map { $0 * b }
            }
        } else {
            let n = aiLockNative > 0 ? aiLockNative : 1
            pts.append(n)
            pts += fmt.secondaryNativeResolutionZoomFactors.map { $0 * n }
        }
        var clean = Array(Set(pts.map { ($0 * 100).rounded() / 100 })).filter { $0 > 0.3 && $0 < 30 }.sorted()
        // titik yang terlalu dekat di bawah titik berikutnya (mis. 0.89 = crop UW tepat sebelum 1x) tidak berguna
        clean = clean.enumerated().filter { i, v in i + 1 >= clean.count || v < clean[i + 1] * 0.85 }.map { $0.element }
        let txt = clean.map { String(format: "%.2g", Double($0)) }.joined(separator: ", ")
        let own = fmt.secondaryNativeResolutionZoomFactors.map { String(format: "%.2g", Double($0)) }.joined(separator: ",")
        Log.camera.info("VIDEO: titik zoom native [\(txt, privacy: .public)] (format aktif: [\(own, privacy: .public)])")
        DispatchQueue.main.async { self.nativeZoomPoints = clean; self.updateZoomQuality() }
    }

    /// main: label kualitas zoom + kekuatan penajaman zoom digital
    private func updateZoomQuality() {
        guard shootMode == .video, !nativeZoomPoints.isEmpty else {
            if !zoomQuality.isEmpty { zoomQuality = "" }
            if previewSharpen != 0 { previewSharpen = 0; videoQueue.async { self.recSharpen = 0; self.recorder?.sharpen = 0 } }
            return
        }
        let z = totalZoom
        let base = nativeZoomPoints.filter { $0 <= z * 1.01 }.max() ?? nativeZoomPoints[0]
        let digital = z / max(base, 0.01)
        let q = digital <= 1.03 ? "Native" : String(format: "Digital %.1fx", Double(digital))
        if q != zoomQuality { zoomQuality = q }
        let sh: Float = sharpenZoom && digital > 1.05 ? Float(min(0.9, 0.25 + (digital - 1) * 0.35)) : 0
        if abs(sh - previewSharpen) > 0.02 || (sh == 0) != (previewSharpen == 0) {
            previewSharpen = sh
            videoQueue.async { self.recSharpen = sh; self.recorder?.sharpen = sh }
        }
    }

    /// lensa fisik yang sedang dipakai kamera virtual
    private func activeLens() -> Lens? {
        guard let d = device, d.isVirtualDevice, let t = d.activePrimaryConstituent?.deviceType else { return nil }
        return [Lens.ultraWide, .wide, .tele].first { $0.deviceType == t }
    }

    /// fps harus masuk salah satu rentang format, kalau tidak AVFoundation melempar NSException
    private static func supportsFps(_ f: AVCaptureDevice.Format, _ fps: Int) -> Bool {
        f.videoSupportedFrameRateRanges.contains { Double(fps) >= $0.minFrameRate - 0.01 && Double(fps) <= $0.maxFrameRate + 0.01 }
    }

    private func maxFps(_ f: AVCaptureDevice.Format) -> Double {
        f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
    }

    /// format kamera untuk resolusi / fps / warna; 10-bit (x420) untuk HLG & Log
    private func pickVideoFormat(_ d: AVCaptureDevice, res: VideoRes, fps: Int, color: VideoColor,
                                 stab: VideoStab) -> AVCaptureDevice.Format? {
        let want = res.size
        let c = d.formats.filter { f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dim.width == want.w, dim.height == want.h else { return false }
            guard Self.supportsFps(f, fps), f.supportedColorSpaces.contains(color.avSpace) else { return false }
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return color.tenBit ? sub == Self.tenBitFmt
                : (sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        }
        return c.sorted { a, b in
            let sa = a.isVideoStabilizationModeSupported(stab.av) ? 0 : 1
            let sb = b.isVideoStabilizationModeSupported(stab.av) ? 0 : 1
            if sa != sb { return sa < sb }
            return maxFps(a) < maxFps(b)
        }.first
    }

    /// sessionQueue: pasang format video sesuai pengaturan (dengan cadangan bila tidak tersedia)
    private func applyVideoFormat() {
        guard inVideo, let d = device else { return }
        let s = videoSnap
        var fps = s.timelapse > 1 ? 30 : (s.fps == .auto ? 30 : s.fps.rawValue)
        let needFps = s.fps == .auto && s.timelapse <= 1 ? 60 : fps
        var res = s.res, color = s.color
        var note = ""
        var f = pickVideoFormat(d, res: res, fps: needFps, color: color, stab: s.stab)
        if f == nil && s.fps == .auto { f = pickVideoFormat(d, res: res, fps: 30, color: color, stab: s.stab) }
        if f == nil && res == .hd {
            // 720p tidak ada di semua lensa / warna -> 1080p
            for alt in [needFps, 30] where f == nil {
                f = pickVideoFormat(d, res: .fhd, fps: alt, color: color, stab: s.stab)
                if f != nil { res = .fhd; if alt != needFps { fps = alt }; note = "720p tidak tersedia di lensa ini -> 1080p" }
            }
        }
        if f == nil && needFps > 60 && res == .uhd {
            res = .fhd
            f = pickVideoFormat(d, res: res, fps: needFps, color: color, stab: s.stab)
            if f != nil { note = "\(needFps) fps hanya 1080p" }
        }
        if f == nil && needFps > 60 {
            for alt in [120, 60] where alt < needFps && f == nil {
                f = pickVideoFormat(d, res: res, fps: alt, color: color, stab: s.stab)
                if f != nil { fps = alt; note = "maks \(alt) fps di lensa ini" }
            }
        }
        if f == nil && color != .sdr {
            color = .sdr
            f = pickVideoFormat(d, res: res, fps: needFps, color: color, stab: s.stab)
            if f != nil { note = "\(s.color.short) tidak tersedia di lensa ini -> Rec.709" }
        }
        guard let fmt = f else {
            Log.camera.error("VIDEO: tidak ada format \(s.res.rawValue, privacy: .public) \(needFps, privacy: .public) fps \(s.color.short, privacy: .public)")
            setStatus("Format video \(s.res.rawValue) \(needFps) fps \(s.color.short) tidak tersedia")
            return
        }
        session.beginConfiguration()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        color.tenBit ? Self.tenBitFmt : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        if (try? d.lockForConfiguration()) != nil {
            d.activeFormat = fmt
            if fmt.supportedColorSpaces.contains(color.avSpace) { d.activeColorSpace = color.avSpace }
            if Self.supportsFps(fmt, fps) {
                let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
                d.activeVideoMinFrameDuration = dur
                d.activeVideoMaxFrameDuration = dur
            } else {
                Log.camera.error("VIDEO: format tidak mendukung \(fps, privacy: .public) fps, pakai default")
            }
            let base = isVirtual ? wideBase : (aiLockNative > 0 ? 1 / aiLockNative : 1)
            d.videoZoomFactor = min(max(s.zoom * base, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            d.unlockForConfiguration()
        }
        if let c = videoOutput.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = s.stab.av }
        }
        session.commitConfiguration()
        fpsApplied = fps
        applyAuto()
        updateNativePoints(d)
        let log = color == .log
        videoQueue.async { self.previewLog = log }
        let fpsText = s.timelapse > 1 ? "TL \(s.timelapse)x" : (s.fps == .auto ? "Auto" : "\(fps)")
        let info = "\(res.rawValue) · \(fpsText) · \(s.codec.short) · \(color.short)"
        Log.camera.info("VIDEO: format \(info, privacy: .public), maks \(self.maxFps(fmt), privacy: .public) fps, stabil \(s.stab.rawValue, privacy: .public) \(note, privacy: .public)")
        DispatchQueue.main.async {
            self.videoInfo = info
            if !note.isEmpty { self.status = note }
        }
    }

    private func applyTorch() {
        let on = torch
        sessionQueue.async {
            guard let d = self.device, d.hasTorch, d.isTorchModeSupported(on ? .on : .off),
                  (try? d.lockForConfiguration()) != nil else { return }
            d.torchMode = on ? .on : .off
            d.unlockForConfiguration()
        }
    }

    /// main: tombol rekam
    func toggleRecording() {
        if isRecording { stopRecording(); return }
        guard shootMode == .video, !isCapturing else { return }
        var snap = makeVideoSnap()
        snap.zoom = totalZoom
        let gain = Double(liveISO) * liveShutter
        let lut = bakeLUTVideo ? captureLUT : nil
        let slow = slowPlayback
        // v0.12: lensa Auto = kamera virtual (tanpa eksposur custom). Kunci ke lensa aktif selama rekam
        // supaya shutter 180 derajat jalan dan lensa tidak melompat di tengah rekaman.
        if lockLensOnRecord, shutter180, aiLensLock == nil, autoLensAvailable, let l = activeLens() {
            setAILensLock(l)
            autoLockedForRec = true
        }
        isRecording = true
        recordSeconds = 0
        sessionQueue.async { self.startRecording(snap, gain: gain, lut: lut, slowPlayback: slow) }
    }

    /// sessionQueue
    private func startRecording(_ s: VideoSnap, gain: Double, lut: CubeLUT?, slowPlayback: Int) {
        guard inVideo, let d = device else {
            DispatchQueue.main.async { self.isRecording = false; self.status = "VIDEO belum siap" }
            return
        }
        // FPS Auto (GCam): 60 bila terang, 30 bila gelap
        var fps = fpsApplied
        if s.fps == .auto && s.timelapse <= 1 {
            let want = gain < 1.5 ? 60 : 30
            if want != fpsApplied, Self.supportsFps(d.activeFormat, want), (try? d.lockForConfiguration()) != nil {
                let dur = CMTime(value: 1, timescale: CMTimeScale(want))
                d.activeVideoMinFrameDuration = dur
                d.activeVideoMaxFrameDuration = dur
                d.unlockForConfiguration()
                fpsApplied = want
            }
            fps = fpsApplied
        }
        let dims = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        let tenBit = CMFormatDescriptionGetMediaSubType(d.activeFormat.formatDescription) == Self.tenBitFmt
        let color: VideoColor = tenBit ? (d.activeColorSpace == .appleLog ? .log : .hlg) : .sdr
        var codec = s.codec
        if codec == .h264 && tenBit && lut == nil { codec = .hevc }      // H.264 tidak 10-bit
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let transform = CGAffineTransform(rotationAngle: (angle - 90) * .pi / 180)
        let playback = s.fps.isSlowMo && s.timelapse <= 1 ? slowPlayback : fps
        let audio = audioInput != nil && playback == fps && s.timelapse <= 1
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = s.timelapse > 1 ? "TL\(s.timelapse)x" : (playback != fps ? "\(fps)to\(playback)" : "\(fps)")
        let name = "BaginCam_\(f.string(from: Date()))_\(dims.width >= 3840 ? "4K" : (dims.width >= 1920 ? "1080p" : "720p"))\(tag)_\(codec.short.replacingOccurrences(of: " ", with: ""))_\(lut != nil ? "LUT" : color.short).mov"
        let cfg = VideoConfig(url: dir.appendingPathComponent(name), width: Int(dims.height), height: Int(dims.width),
                              sensorFps: fps, playbackFps: playback, timelapse: max(1, s.timelapse), codec: codec,
                              color: color, audio: audio, transform: transform, bake: lut, bakeLog: lut != nil && color == .log)
        do {
            let r = try VideoRecorder(cfg)
            videoQueue.async { r.sharpen = self.recSharpen; self.recorder = r }
            // lensa Auto tanpa kunci: pindah lensa hanya saat zoom diubah (tidak karena cahaya / jarak fokus)
            if d.isVirtualDevice, !d.constituentDevices.isEmpty, (try? d.lockForConfiguration()) != nil {
                d.setPrimaryConstituentDeviceSwitchingBehavior(.restricted, restrictedSwitchingBehaviorConditions: [.videoZoomChanged])
                d.unlockForConfiguration()
            }
            Log.camera.info("VIDEO: rekam \(name, privacy: .public) \(cfg.width, privacy: .public)x\(cfg.height, privacy: .public), sudut \(Double(angle), privacy: .public), audio \(audio, privacy: .public)")
            DispatchQueue.main.async {
                self.recordStart = Date()
                self.status = "Merekam \(name)"
                self.recordTimer?.invalidate()
                self.recordTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.recordSeconds = Date().timeIntervalSince(self.recordStart)
                }
            }
        } catch {
            Log.camera.error("VIDEO: perekam gagal \(String(describing: error), privacy: .public)")
            DispatchQueue.main.async { self.isRecording = false; self.status = "Rekam gagal: \(error.localizedDescription)" }
        }
    }

    /// main
    private func stopRecording() {
        recordTimer?.invalidate()
        recordTimer = nil
        let saveTo = videoSaveTo
        status = "Menyimpan video..."
        videoQueue.async {
            guard let r = self.recorder else { DispatchQueue.main.async { self.isRecording = false }; return }
            self.recorder = nil
            let dur = r.seconds, dropped = r.droppedFrames
            self.sessionQueue.async {
                if let d = self.device, d.isVirtualDevice, (try? d.lockForConfiguration()) != nil {
                    d.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                    d.unlockForConfiguration()
                }
            }
            r.stop { url, err in
                DispatchQueue.main.async {
                    self.isRecording = false
                    if self.autoLockedForRec {
                        self.autoLockedForRec = false
                        self.setAILensLock(nil)
                    }
                }
                guard let url else {
                    Log.camera.error("VIDEO: simpan gagal \(String(describing: err), privacy: .public)")
                    self.setStatus("Video gagal disimpan: \(err?.localizedDescription ?? "-")")
                    return
                }
                Log.camera.info("VIDEO: selesai \(url.lastPathComponent, privacy: .public), \(dur, privacy: .public) s, frame hilang \(dropped, privacy: .public)")
                self.saveVideo(url, to: saveTo, seconds: dur, dropped: dropped)
            }
        }
    }

    private func saveVideo(_ url: URL, to: VideoSaveTo, seconds: Double, dropped: Int) {
        // thumbnail untuk tombol galeri
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            let t = UIImage(cgImage: cg)
            DispatchQueue.main.async { self.lastThumb = t; self.lastImageData = nil; self.lastFileName = url.lastPathComponent }
        }
        let mins = Int(seconds) / 60, secs = Int(seconds) % 60
        let summary = String(format: "%02d:%02d", mins, secs) + (dropped > 0 ? " · \(dropped) frame hilang" : "")
        // v0.12.1: "AI setelah rekam" -> file asli disimpan dulu untuk AI Upscale (dihapus setelah layar AI ditutup)
        let keepForAI = aiAfterRecord && seconds > 0.3
        guard to != .files else {
            setStatus("Video tersimpan di Files: \(url.lastPathComponent) (\(summary))")
            if keepForAI { DispatchQueue.main.async { self.pendingUpscale = url } }
            return
        }
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            let opt = PHAssetResourceCreationOptions()
            opt.shouldMoveFile = to == .photos && !keepForAI
            req.addResource(with: .video, fileURL: url, options: opt)
        }) { ok, err in
            if keepForAI { DispatchQueue.main.async { self.pendingUpscale = url } }
            if ok {
                self.setStatus("Video tersimpan (\(to.rawValue)): \(summary)")
            } else {
                Log.camera.error("VIDEO: simpan ke Foto gagal \(String(describing: err), privacy: .public)")
                self.setStatus("Simpan ke Foto gagal, file tetap di Files: \(url.lastPathComponent)")
            }
        }
    }

    /// main (~4x/detik): meter audio, ISO otomatis untuk shutter 180 derajat, sisa waktu rekam
    private func videoReadout() {
        if let ch = audioOutput.connections.first?.audioChannels.first { audioLevel = ch.averagePowerLevel }
        readoutTick += 1
        if readoutTick % 8 == 0 {
            let free = (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
            let fps = videoFps == .auto ? 60 : videoFps.rawValue
            let mbps = videoCodec.mbps(videoRes, fps: timelapse > 1 ? 1 : fps, tenBit: videoColor.tenBit)
            minutesLeft = Int(Double(free) * 8 / (mbps * 1_000_000) / 60) * (timelapse > 1 ? timelapse : 1)
            let th = ProcessInfo.processInfo.thermalState.rawValue
            if th != thermal {
                Log.camera.info("Suhu HP: \(th, privacy: .public) (0 normal, 1 hangat, 2 panas, 3 kritis), rekam \(self.isRecording, privacy: .public)")
                thermal = th
            }
        }
        if !shutter180 && needND { needND = false }
        guard shutter180, !manualExposure else { return }
        sessionQueue.async {
            guard self.inVideo, let d = self.device else { return }
            // v0.11.1: kamera virtual (lensa Auto) tidak mendukung eksposur custom -> dulu crash (NSException)
            guard d.isExposureModeSupported(.custom) else {
                if self.ndWarned { self.ndWarned = false; DispatchQueue.main.async { self.needND = false } }
                if !self.shutter180Warned {
                    self.shutter180Warned = true
                    Log.camera.info("VIDEO: 180° dilewati, \(d.localizedName, privacy: .public) tidak dukung eksposur custom")
                    self.setStatus("180° aktif hanya bila lensa dikunci (UW/Utama/Tele)")
                }
                return
            }
            guard (try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() }
            let fmt = d.activeFormat
            let fps = max(self.fpsApplied, 1)
            let t180 = min(max(1.0 / (2 * Double(fps)), fmt.minExposureDuration.seconds), fmt.maxExposureDuration.seconds)
            // v0.12.1: kerja dengan "jumlah cahaya" ISO x waktu. Terlalu terang untuk 1/(2xfps) di ISO minimum
            // (siang terik tanpa filter ND) -> shutter dipercepat, bukan video terbakar (v0.12.0: 60-76 % piksel putih).
            let curT = d.exposureDuration.seconds
            var light = Double(d.iso) * (curT.isFinite && curT > 0 ? curT : t180)
            if d.exposureMode == .custom {
                let off = d.exposureTargetOffset
                guard off.isFinite, abs(off) > 0.1 else { return }
                light *= pow(2, -Double(max(-0.5, min(0.5, off))))
            }
            guard light.isFinite, light > 0 else { return }
            let minISO = Double(fmt.minISO), maxISO = Double(fmt.maxISO)
            var t = t180
            if light / t < minISO { t = max(light / minISO, fmt.minExposureDuration.seconds) }   // perlu ND
            let iso = Float(min(max(light / t, minISO), maxISO))
            let tooBright = t < t180 * 0.9
            if tooBright != self.ndWarned {
                self.ndWarned = tooBright
                if tooBright {
                    Log.camera.info("VIDEO: terlalu terang untuk 180° -> shutter 1/\(Int((1 / t).rounded()), privacy: .public) (butuh ND)")
                    self.setStatus("Terlalu terang untuk 180°: shutter dipercepat (pakai filter ND untuk gerak halus)")
                }
                DispatchQueue.main.async { self.needND = tooBright }
            }
            guard iso.isFinite, t.isFinite, t > 0 else { return }
            let dur = CMTimeClampToRange(CMTime(seconds: t, preferredTimescale: 1_000_000_000),
                                         range: CMTimeRange(start: fmt.minExposureDuration, end: fmt.maxExposureDuration))
            d.setExposureModeCustom(duration: dur, iso: iso, completionHandler: nil)
        }
    }

    // MARK: capture
    /// Tombol shutter / tombol volume: pakai timer bila diatur.
    func shutterPressed() {
        if shootMode == .video {
            // v0.12.4: timer juga untuk mulai rekam (tekan lagi saat hitung mundur = batal)
            if countdown > 0 { countdown = 0; return }
            if isRecording || timerSeconds == 0 { toggleRecording(); return }
        } else {
            guard !isCapturing, countdown == 0 else { return }
            guard timerSeconds > 0 else { startBurst(); return }
        }
        countdown = timerSeconds
        let mode = shootMode
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard self.countdown > 0, self.shootMode == mode else { self.countdown = 0; return }
                self.countdown -= 1
                if self.countdown == 0 {
                    if mode == .video { if !self.isRecording { self.toggleRecording() } } else { self.startBurst() }
                } else { tick() }
            }
        }
        tick()
    }

    func cancelCountdown() { countdown = 0 }

    /// jumlah frame HDR+ menurut kecerahan (ISO x waktu eksposur saat ini)
    func autoFrameCount() -> Int {
        let iso = Double(liveISO), t = liveShutter
        guard iso > 0, t > 0 else { return 8 }
        let gain = iso * t          // makin besar = makin gelap
        if gain < 0.25 { return 6 }   // terang (mis. ISO 50 @ 1/500)
        if gain < 2 { return 8 }
        if gain < 10 { return 12 }
        return 15
    }

    func startBurst() {
        guard !isCapturing else { return }
        // FOTO: Auto memilih mesin saat shutter ditekan; Live / flash nyala = proses Apple (semua proses)
        if shootMode == .photo && (photoProcess == .auto || livePhoto || flash == .on) {
            let gain = Double(liveISO) * liveShutter
            let apple = livePhoto || flash == .on || photoProcess == .apple || gain < 2
            let want: Mode = apple ? .heif : .hdrplus
            if mode != want { mode = want }
            Log.camera.info("Proses \(self.photoProcess.rawValue, privacy: .public): ISO x t \(gain, privacy: .public), live \(self.livePhoto, privacy: .public), flash \(self.flash.rawValue, privacy: .public) -> \(want.rawValue, privacy: .public)")
        }
        isCapturing = true
        previewFrozen = true
        // proses tetap jalan sebentar bila app ditinggal (iOS memberi ~30 detik)
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BaginCam processing") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        let m = mode
        let night = shootMode == .night
        let count = m == .heif ? 1 : (m == .hdrplus && autoFrames ? autoFrameCount() : max(m == .hdrplus ? 2 : 1, burstCount))
        let merge = mergeMethod
        let useAI = zoomAIEnabled
        let method = zoomMethod
        let lensNative: CGFloat = lens == .tele ? 5 : (lens == .ultraWide ? 0.5 : 1)
        let keep = saveFrames, nr = hdrNoiseReduction, res = outputMP
        let fmt = outputFormat, lut = bakeLUT ? captureLUT : nil
        let tz = totalZoom, model = srModel, strength = aiStrength, tf = textFocus
        let steady = deviceSteady
        let motion = motionLevel?() ?? -1
        let liveReq = m == .heif && livePhoto && liveAvailable
        let flashSet = flash, asp = aspect
        sessionQueue.async {
            self.burstAuto = true          // AE/AWB/AF dikunci selama burst; bagian manual tetap manual
            self.burstMode = m
            self.burstSaveFrames = keep
            self.burstNR = nr
            self.burstMerge = merge
            self.burstOutputMP = res
            self.burstFormat = fmt
            self.burstLUT = lut
            self.burstTotalZoom = tz
            self.burstSRModel = model
            self.burstStrength = useAI ? strength : 0
            self.restoreZoomAfterBurst = false
            self.burstTextFocus = tf
            self.burstZoomed = false
            self.burstAIMultiFrame = false
            self.burstAIFull = false
            self.burstAppleZoomAI = false
            self.burstNight = night
            self.burstAspect = asp
            self.burstFlash = flashSet
            self.burstLive = liveReq
            self.livePending = nil
            self.liveMovieURL = nil
            self.burstDisplayZoom = Self.usesVirtual(m) ? tz : tz * lensNative
            self.burstLensName = self.lens.displayName
            // orientasi foto mengikuti cara HP dipegang (potret/lanskap)
            if let rc = self.rotationCoordinator, let c = self.photoOutput.connection(with: .video) {
                let a = rc.videoRotationAngleForHorizonLevelCapture
                if c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
            }
            var frames = count
            var delay = m.isBurst ? 0.15 : 0.0
            var hint = ""

            // zoom melewati lensa optik? (crop di atas lensa pilihan iOS / lensa yang dikunci)
            var base: CGFloat = 1
            var lensName = self.lens.displayName
            var nativeLong = 4032
            let srcISO = self.device?.iso ?? 400
            let srcDur = self.device?.exposureDuration.seconds ?? 1.0 / 30
            let virtualWide = self.isVirtual ? self.wideBase : 1
            if let d = self.device, d.isVirtualDevice, let p = d.activePrimaryConstituent {
                base = self.lensBase[p.deviceType] ?? 1
                lensName = Self.name(of: p.deviceType)
                nativeLong = self.maxDimensions(of: p).map { Int(max($0.width, $0.height)) } ?? 4032
            } else if let d = self.device {
                if self.aiLockNative > 0 {
                    base = self.aiLockNative
                    lensName = self.aiLockNative >= 2 ? "Tele" : (self.aiLockNative < 0.9 ? "Ultra Wide" : (d.position == .front ? "Depan" : "Utama"))
                }
                nativeLong = self.maxDimensions(of: d).map { Int(max($0.width, $0.height)) } ?? 4032
            }
            let crop = max(1, tz * virtualWide / base)
            let canZoom = m == .hdrplus || m == .heif
            let zoomed = canZoom && Self.usesVirtual(m) && crop > 1.05
            let bayerOK = self.photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
                || self.photoOutput.isAppleProRAWEnabled
            var zm = night ? ZoomMethod.superRes : method
            if zm == .auto { zm = (lensName == "Tele" || crop >= 3) ? .superRes : .fullCrop }
            if zm == .superRes && !bayerOK { zm = .fullCrop }
            // v0.12.1: Super Res di lensa utama < 3x saat terang: 12 MP digabung lalu di-crop hanya ~2000 px
            // (AI 2.8x -> tekstur seperti lukisan, IMG_6958). Crop sensor 48 MP memberi detail asli 2x lipat.
            if zm == .superRes && !night && lensName == "Utama" && crop < 3 && nativeLong >= 8000
                && Double(srcISO) * srcDur < 0.25 {
                zm = .fullCrop
                Log.camera.info("Super Res -> Crop penuh 48MP (utama \(Double(crop), privacy: .public)x, terang)")
            }

            let bayerBurst = (m == .hdrplus && !zoomed) || (zoomed && zm == .superRes)
            let singleFull = zoomed && zm == .fullCrop
            if zoomed && zm == .apple {
                // zoom Apple apa adanya (kamera virtual, seperti kamera bawaan); + AI: perkecil ke detail asli lalu AI
                self.burstMode = .heif
                self.burstAppleZoomAI = useAI
                self.burstCrop = crop
                // v0.10.0: sensor/crop (621 px di 13x utama) terlalu kecil - Apple (remosaic + multi-frame)
                // menyimpan ~2x lebih banyak detail; diperkecil sejauh itu AI mengubah huruf jadi balok
                self.burstRealLong = max(512, Int(2 * Double(nativeLong) / Double(crop)))
                frames = 1
            } else if bayerBurst || singleFull {
                self.burstMode = bayerBurst ? .hdrplus : .heif
                self.burstZoomed = zoomed
                // Untuk memotret pindah sementara ke lensa FISIK pilihan iOS: kamera virtual hanya memberi
                // 12MP & tanpa Bayer RAW (log v0.6.0). Live dimatikan sementara (resolusi penuh / RAW).
                self.liveSuspended = true
                self.applyLive()
                if let d = self.device, d.isVirtualDevice, let p = d.activePrimaryConstituent {
                    // eksposur & WB preview (sensor sama) dibawa ke lensa fisik (v0.9.1: AWB belum stabil -> pink)
                    var tt: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues?
                    let g = d.deviceWhiteBalanceGains
                    if d.maxWhiteBalanceGain >= 1, g.redGain > 0, g.greenGain > 0, g.blueGain > 0 {
                        tt = d.temperatureAndTintValues(for: Self.clamp(g, d.maxWhiteBalanceGain))
                    }
                    self.install(p, mirrored: false)
                    self.isVirtual = false
                    self.applyRawMode(.aiZoom)
                    if (try? p.lockForConfiguration()) != nil {
                        let pf = p.activeFormat
                        if p.isExposureModeSupported(.custom) {
                            let s = min(max(srcDur, pf.minExposureDuration.seconds), pf.maxExposureDuration.seconds)
                            p.setExposureModeCustom(duration: CMTime(seconds: s, preferredTimescale: 1_000_000_000),
                                                    iso: min(max(srcISO, pf.minISO), pf.maxISO), completionHandler: nil)
                        }
                        if let tt, p.isWhiteBalanceModeSupported(.locked), p.maxWhiteBalanceGain >= 1 {
                            p.setWhiteBalanceModeLocked(with: Self.clamp(p.deviceWhiteBalanceGains(for: tt), p.maxWhiteBalanceGain),
                                                        completionHandler: nil)
                        }
                        if p.isFocusModeSupported(.continuousAutoFocus) && !self.manualS.focus { p.focusMode = .continuousAutoFocus }
                        p.unlockForConfiguration()
                    }
                    self.switchedToPhysicalForMF = true
                    delay = 0.5   // eksposur & WB sudah sama; cukup waktu untuk fokus
                    Log.camera.info("Capture: pindah ke lensa fisik \(p.localizedName, privacy: .public)")
                } else if let d = self.device, (try? d.lockForConfiguration()) != nil {
                    // lensa dikunci (atau tanpa kamera virtual): sudah lensa fisik, cukup zoom 1x.
                    // Ganti zoom membuat AF mencari ulang -> fokus tengah lagi & beri waktu (v0.10.0: Crop penuh buram)
                    d.videoZoomFactor = 1
                    if !self.manualS.focus, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                        d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                        d.focusMode = .autoFocus
                    }
                    d.unlockForConfiguration()
                    self.restoreZoomAfterBurst = true
                    delay = 0.7
                }
                self.burstCrop = crop
                if bayerBurst {
                    self.burstAIMultiFrame = true
                    frames = m == .hdrplus ? count : 8
                } else {
                    self.burstAIFull = true
                    frames = 1
                }
                // MALAM: shutter lebih lama, ISO lebih rendah (total eksposur sama), lebih banyak frame
                if night, let p = self.device, (try? p.lockForConfiguration()) != nil {
                    let pf = p.activeFormat
                    let plan = Self.nightPlan(iso: srcISO, shutter: srcDur, minISO: pf.minISO, steady: steady, tele: lensName == "Tele")
                    let t = min(plan.shutter, pf.maxExposureDuration.seconds)
                    if p.isExposureModeSupported(.custom) {
                        p.setExposureModeCustom(duration: CMTime(seconds: t, preferredTimescale: 1_000_000_000),
                                                iso: min(max(plan.iso, pf.minISO), pf.maxISO), completionHandler: nil)
                    }
                    p.unlockForConfiguration()
                    frames = plan.frames
                    delay = max(delay, 2 * t + 0.3)
                    let tt = t >= 0.5 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))"
                    hint = String(format: "MALAM: tahan HP ~%.0f s (%d x %@)", Double(frames) * t + 0.5, frames, tt)
                    Log.camera.info("MALAM: \(frames, privacy: .public) frame x \(t, privacy: .public)s ISO \(plan.iso, privacy: .public) (asal ISO \(srcISO, privacy: .public) \(srcDur, privacy: .public)s, diam \(steady, privacy: .public), gyro \(motion, privacy: .public) rad/s)")
                }
            }
            self.burstLensName = lensName
            let hintText = hint
            DispatchQueue.main.async { self.captureHint = hintText }
            self.burstRemaining = frames
            self.burstIndex = 0
            self.savedCount = 0
            self.hdrFrames = []
            self.hdrRef = nil
            let bm = self.burstMode
            self.burstDir = Self.makeBurstDir(prefix: night ? "MALAM" : (bm == .hdrplus ? "HDRPLUS" : (bm == .heif ? "FOTO" : "BURST")))
            let isMulti = bm.isBurst || self.burstAIMultiFrame
            Log.camera.info("Capture mulai: \(frames, privacy: .public) frame, mode \(bm.rawValue, privacy: .public)\(night ? " MALAM" : "", privacy: .public), zoom total \(Double(tz), privacy: .public)x, lensa \(lensName, privacy: .public), crop \(Double(crop), privacy: .public)x, cara zoom \(zoomed ? zm.rawValue : "-", privacy: .public), AI \(useAI, privacy: .public), MF \(self.burstAIMultiFrame, privacy: .public), rasio \(asp.rawValue, privacy: .public), live \(liveReq, privacy: .public)")
            self.setStatus(isMulti ? "Burst 0/\(frames)" : "Memotret...")
            // kunci AE/AWB/AF SETELAH lensa stabil, lalu mulai capture
            self.sessionQueue.asyncAfter(deadline: .now() + delay) {
                if isMulti { self.lockCurrent() }
                self.sessionQueue.asyncAfter(deadline: .now() + (isMulti ? 0.15 : 0)) { self.captureNext() }
            }
        }
    }

    private func captureNext() {
        guard burstRemaining > 0 else { finishBurst(); return }
        burstRemaining -= 1
        burstIndex += 1
        photoOutput.capturePhoto(with: makeSettings(burstMode), delegate: self)
    }

    private var collectsBayer: Bool { burstMode == .hdrplus || (burstMode == .aiZoom && burstAIMultiFrame) }

    private func finishBurst() {
        if burstAuto && (burstMode.isBurst || burstAIMultiFrame) { applyAuto() }
        if switchedToPhysicalForMF {
            switchedToPhysicalForMF = false
            restoreZoomAfterBurst = false
            enterAIZoom(zoom: burstTotalZoom)
        }
        if restoreZoomAfterBurst, let d = device, (try? d.lockForConfiguration()) != nil {
            let base = isVirtual ? wideBase : (aiLockNative > 0 ? 1 / aiLockNative : 1)
            d.videoZoomFactor = min(max(burstTotalZoom * base, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            if d.isVirtualDevice {
                d.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            }
            d.unlockForConfiguration()
        }
        if liveSuspended {
            liveSuspended = false
            applyLive()
        }
        let n = burstIndex, dir = burstDir
        if let lp = livePending {
            livePending = nil
            saveLive(lp.data, movie: liveMovieURL, fileName: lp.name, dir: dir)
            liveMovieURL = nil
        }
        DispatchQueue.main.async { self.previewFrozen = false }
        Log.camera.info("Capture selesai: \(n, privacy: .public) frame -> \(dir?.lastPathComponent ?? "-", privacy: .public)")
        if collectsBayer {
            let frames = hdrFrames, ref = hdrRef, nr = burstNR, ai = burstMode == .aiZoom
            hdrFrames = []
            hdrRef = nil
            processQueue.async { self.processHDRPlus(frames: frames, ref: ref, dir: dir, noiseReduction: nr, forAIZoom: ai) }
        } else if !burstZoomed && !burstAppleZoomAI {
            finish("Tersimpan \(n) frame (\(dir?.lastPathComponent ?? "-"))")
        }
    }

    private func finish(_ message: String) {
        DispatchQueue.main.async {
            self.isCapturing = false
            self.previewFrozen = false
            self.status = message
            self.progress = nil
            self.progressText = ""
            self.captureHint = ""
            // Auto / Live / flash mengganti mesin untuk satu jepretan -> kembali ke pilihan pengguna
            let base = Self.internalMode(self.shootMode, self.photoProcess, self.proFormat)
            if self.mode != base && Self.usesVirtual(self.mode) && Self.usesVirtual(base) { self.mode = base }
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// progres per langkah + perkiraan sisa waktu
    private func report(_ label: String, _ done: Int, _ total: Int, since t0: CFAbsoluteTime) {
        let frac = total > 0 ? Double(done) / Double(total) : 0
        let el = CFAbsoluteTimeGetCurrent() - t0
        let eta = frac > 0.02 ? el / frac - el : 0
        let text = String(format: "%@ %d/%d · %.0f%%%@", label, done, total, frac * 100,
                          eta > 1 ? String(format: " · sisa ~%.0f s", eta) : "")
        DispatchQueue.main.async {
            self.progress = frac
            self.progressText = text
            self.status = "\(text) - jangan tinggalkan app"
        }
    }

    private func makeSettings(_ m: Mode) -> AVCapturePhotoSettings {
        let raws = photoOutput.availableRawPhotoPixelFormatTypes
        var s: AVCapturePhotoSettings?
        let wantBayer = m == .bayer || m == .hdrplus || (m == .aiZoom && burstAIMultiFrame)
        if wantBayer, let fmt = raws.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
            s = AVCapturePhotoSettings(rawPixelFormatType: fmt)
            s?.photoQualityPrioritization = .speed
        } else if m == .proraw, let fmt = raws.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            s = AVCapturePhotoSettings(rawPixelFormatType: fmt)
            s?.photoQualityPrioritization = .quality
        }
        let settings = s ?? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        if s == nil { settings.photoQualityPrioritization = m == .aiZoom ? .quality : .balanced }
        var live = false
        if s == nil {
            if photoOutput.supportedFlashModes.contains(burstFlash.avMode) { settings.flashMode = burstFlash.avMode }
            if burstLive && !burstZoomed && photoOutput.isLivePhotoCaptureEnabled {
                settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("live_\(UUID().uuidString).mov")
                live = true
            }
        }
        // burst: hanya frame pertama yang berbunyi (bila iOS / wilayah mengizinkan)
        if #available(iOS 18.0, *), burstIndex > 1, photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }

        // resolusi: HEIF/ProRAW 24/48MP -> sensor penuh; AI Zoom lensa utama -> penuh; Bayer ~12MP
        if let d = device {
            let full = maxDimensions(of: d), std = standardDimensions(of: d)
            let wantFull = !wantBayer && ((m == .aiZoom && burstAIFull) || (m == .heif && burstZoomed)
                                          || (burstOutputMP != .mp12 && (m == .heif || m == .proraw)))
            if let dims = (wantFull && !live) ? full : std,
               Int(dims.width) * Int(dims.height) <= Int(photoOutput.maxPhotoDimensions.width) * Int(photoOutput.maxPhotoDimensions.height) {
                settings.maxPhotoDimensions = dims
            }
        }
        return settings
    }

    // MARK: upscale (processQueue)
    private func upscaler(for m: SRModel) -> SRUpscaler? {
        if let u = upscalers[m] { return u }
        if upscalerFailed.contains(m) { return nil }
        setStatus("Memuat model AI \(m.rawValue)...")
        if let u = SRUpscaler(model: m) { upscalers[m] = u; return u }
        upscalerFailed.insert(m)
        return nil
    }

    /// Perbesar area `crop` ke sisi panjang `target`. AI dipakai hanya bila faktor >= minAIFactor,
    /// lalu dicampur dengan pembesaran biasa (strength). Mengembalikan (gambar, catatan metode).
    private func upscale(_ src: CGImage, crop: CGRect, target: Int, model: SRModel, strength: Double,
                         minAIFactor: Double, label: String) -> (CGImage?, String) {
        let L = Double(max(crop.width, crop.height))
        let need = Double(target) / L
        guard let plain0 = src.cropping(to: crop) else { return (nil, "crop gagal") }
        if need <= 1.001 { return (SRUpscaler.resize(plain0, longSide: target) ?? plain0, "crop") }
        guard let plain = SRUpscaler.resize(plain0, longSide: target) else { return (plain0, "resize gagal") }
        guard need >= minAIFactor, strength > 0.01 else { return (plain, "Lanczos") }
        guard let sr = upscaler(for: model) else { return (plain, "AI gagal: model \(model.rawValue) tidak bisa dimuat") }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let up = sr.upscale(src, crop: crop, outScale: min(need, Double(SRUpscaler.scale)), progress: { d, n in
            self.report("\(label) AI \(model.rawValue)", d, n, since: t0)
        }) else {
            return (plain, "AI gagal: \(sr.lastError ?? "prediksi gagal")")
        }
        let upT = SRUpscaler.resize(up, width: plain.width, height: plain.height) ?? up
        if burstTextFocus {
            // area tulisan: AI lebih kuat supaya huruf terbaca; area lain tetap campuran biasa
            let boxes = TextBoost.mergedBoxes(ai: upT, plain: plain)
            if !boxes.isEmpty {
                setStatus("\(label): baca tulisan (OCR) \(boxes.count) area...")
                let dec = TextBoost.decide(plain: plain, ai: upT, boxes: boxes)
                let nAI = dec.filter { $0.useAI }.count
                let detail = dec.prefix(8).map { String(format: "%.2f/%.2f~%.2f", $0.confAI, $0.confPlain, $0.sim) }
                    .joined(separator: " ")
                Log.sr.info("Fokus tulisan: \(boxes.count, privacy: .public) area, AI menang \(nAI, privacy: .public) (OCR ai/asli: \(detail, privacy: .public))")
                if let comp = TextBoost.compose(plain: plain, ai: upT, strength: strength,
                                                textStrength: max(strength, 0.9), decisions: dec) {
                    return (comp, "AI \(model.rawValue) \(Int((strength * 100).rounded()))% + teks \(nAI)/\(boxes.count) AI")
                }
            }
        }
        let mixed = RawDeveloper.blend(plain: plain, ai: upT, strength: strength) ?? upT
        return (mixed, "AI \(model.rawValue) \(Int((strength * 100).rounded()))%")
    }

    // MARK: HDR+
    private func processHDRPlus(frames: [BayerFrame], ref: AVCapturePhoto?, dir: URL?, noiseReduction: Double,
                                forAIZoom: Bool) {
        guard let ref, let refPB = ref.pixelBuffer, let merger = self.merger, frames.count >= 2 else {
            Log.hdr.error("HDR+ batal: frame \(frames.count, privacy: .public), ref \(ref != nil, privacy: .public)")
            finish("HDR+ gagal: frame Bayer tidak lengkap (\(frames.count))")
            return
        }
        setStatus("Memproses HDR+ \(frames.count) frame...")
        // DNG referensi dulu: butuh NoiseProfile & black/white untuk merge frekuensi
        guard let refDNG = ref.fileDataRepresentation() else {
            finish("HDR+ gagal: DNG referensi kosong")
            return
        }
        let fs = HDRPlusMerger.fullScale(format: CVPixelBufferGetPixelFormatType(refPB), frame: frames[0])
        var freq: FreqConfig?
        if burstMerge == .frequency, let inf = DNGWriter.info(refDNG), inf.noiseS > 0 {
            // satuan DNG (12-bit) -> satuan pixel buffer (mis. 14-bit): bagi skala
            let k = fs.full > Double(inf.white) * 1.5 ? (fs.full + 1) / Double(inf.white + 1) : 1
            let c = Float(pow(2.0, (noiseReduction - 10) / 2))     // NR 18 -> c 16 (hasil uji PC)
            freq = FreqConfig(noiseS: Float(inf.noiseS), noiseO: Float(inf.noiseO),
                              black: Float(Double(inf.black) * k), range: Float(Double(inf.white - inf.black) * k), c: c)
        }
        let tm = CFAbsoluteTimeGetCurrent()
        guard let r = merger.merge(frames, noiseReduction: noiseReduction, freq: freq, progress: { i, n in
            self.report("Merge HDR+ \(freq != nil ? "frekuensi" : "spasial")", i, n, since: tm)
        }) else {
            finish("HDR+ gagal saat merge (lihat log)")
            return
        }
        // tulis DNG sendiri (replacementRawPixelBuffer diabaikan iOS untuk Bayer - bug v0.4.0)
        let px = r.buffer.contents().bindMemory(to: UInt16.self, capacity: r.width * r.height)
        let dng: Data
        var highlight: Double?
        do {
            let w = try DNGWriter.rewrite(original: refDNG, pixels: px, width: r.width, height: r.height,
                                          software: "BaginCam HDR+ \(frames.count) frame", sourceFullScale: fs.full)
            dng = w.data
            highlight = Self.highlightLevel(px, count: r.width * r.height, scale: w.scale, black: w.black, white: w.white)
            Log.hdr.info("RAW \(fs.bits, privacy: .public), maks data \(fs.maxValue, privacy: .public), DNG white \(w.white, privacy: .public) -> skala \(w.scale, privacy: .public)")
        } catch {
            Log.hdr.error("Tulis DNG gagal: \(String(describing: error), privacy: .public)")
            finish("HDR+ gagal menulis DNG: \(error)")
            return
        }
        let w = r.meanWeights.isEmpty ? 0 : r.meanWeights.reduce(0, +) / Float(r.meanWeights.count)

        if forAIZoom || burstZoomed {
            if !forAIZoom && burstFormat.wantsDNG { save(dng, fileName: "HDRPLUS_\(frames.count)f.dng", dir: dir) }
            // AI Zoom multi-frame / HDR+ zoom: kembangkan hasil merge -> crop -> upscale
            guard let img = RawDeveloper.develop(dng: dng, highlight: highlight, metering: 1 / max(1, Double(burstCrop)),
                                                 night: burstNight),
                  let cg = RawDeveloper.cgImage(img) else {
                finish("AI Zoom MF gagal mengembangkan RAW")
                return
            }
            processAIZoomImage(cg, properties: img.properties, dir: dir, multiFrame: frames.count)
            return
        }

        let fmt = burstFormat, lut = burstLUT, res = burstOutputMP
        var saved: [String] = []
        if fmt.wantsDNG {
            save(dng, fileName: "HDRPLUS_\(frames.count)f.dng", dir: dir)
            saved.append("DNG")
        }
        if fmt.wantsHEIF || fmt.wantsJPEG {
            setStatus("HDR+: mengembangkan RAW...")
            var rendered = false
            if var img = RawDeveloper.develop(dng: dng, highlight: highlight, metering: burstZoomed ? 1 / max(1, Double(burstCrop)) : 1,
                                              night: burstNight) {
                if burstAspect != .r43 {
                    img = img.cropped(to: burstAspect.rect(in: img.extent)).settingProperties(img.properties)
                }
                // 24/48MP: data Bayer 12MP diperbesar (AI Cepat dicampur Lanczos)
                if res != .mp12, let cg = RawDeveloper.cgImage(img) {
                    let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
                    let (up, note) = upscale(cg, crop: full, target: res.longSide, model: .fast,
                                             strength: burstStrength, minAIFactor: 1.2, label: "HDR+ \(res.label)")
                    if let up {
                        img = CIImage(cgImage: up).settingProperties(img.properties)
                        saved.append(note)
                    }
                }
                let final = RawDeveloper.applyLUT(img, lut)
                if let data = fmt.wantsJPEG ? RawDeveloper.encodeJPEG(final) : RawDeveloper.encodeHEIF(final) {
                    let ext = fmt.wantsJPEG ? "jpg" : "heic"
                    save(data, fileName: "\(burstNight ? "MALAM" : "HDRPLUS")_\(frames.count)f_\(res.label)\(lut != nil ? "_LUT" : "").\(ext)", dir: dir)
                    saved.append("\(ext.uppercased()) \(res.label)")
                    rendered = true
                }
            }
            if !rendered && !fmt.wantsDNG {
                save(dng, fileName: "HDRPLUS_\(frames.count)f.dng", dir: dir)
                saved.append("DNG (render HEIF/JPEG gagal)")
            }
        }
        let how = r.meanWeights.isEmpty ? "frekuensi" : String(format: "spasial bobot %.2f", w)
        finish(String(format: "HDR+ %d frame %.1f s (%@) -> %@", frames.count, r.seconds, how,
                      saved.joined(separator: " + ")))
    }

    /// persentil 99.9 data hasil merge, ternormalisasi 0..1 (black..white DNG) - sampel tiap 5 piksel
    static func highlightLevel(_ px: UnsafePointer<UInt16>, count: Int, scale: Double, black: Int, white: Int) -> Double {
        var hist = [Int](repeating: 0, count: 1024)
        var n = 0
        let range = Double(max(1, white - black))
        for i in stride(from: 0, to: count, by: 5) {
            let v = (Double(px[i]) * scale - Double(black)) / range
            hist[min(1023, max(0, Int(v * 1023)))] += 1
            n += 1
        }
        var acc = 0
        let target = Int(Double(n) * 0.999)
        for (b, c) in hist.enumerated() {
            acc += c
            if acc >= target { return Double(b) / 1023 }
        }
        return 1
    }

    // MARK: AI Zoom
    private func processAIZoom(_ photo: AVCapturePhoto, dir: URL?) {
        guard let cg = photo.cgImageRepresentation() else {
            finish("AI Zoom gagal: foto kosong")
            return
        }
        processAIZoomImage(cg, properties: photo.metadata, dir: dir, multiFrame: 0)
    }

    /// crop tengah sesuai burstCrop -> upscale ke resolusi output -> HEIC.
    private func processAIZoomImage(_ cg: CGImage, properties: [String: Any], dir: URL?, multiFrame: Int,
                                    cropOverride: Double? = nil, method: String = "") {
        let W = cg.width, H = cg.height
        let c = max(1, cropOverride ?? Double(burstCrop))
        let cw = max(16, Int(Double(W) / c)) & ~1, ch = max(16, Int(Double(H) / c)) & ~1
        var rect = CGRect(x: (W - cw) / 2, y: (H - ch) / 2, width: cw, height: ch)
        if burstAspect != .r43 { rect = burstAspect.rect(in: rect).integral }
        let res = burstOutputMP
        let (img0, note) = upscale(cg, crop: rect, target: res.longSide, model: burstSRModel,
                                   strength: burstStrength, minAIFactor: 1.4, label: "AI Zoom")
        guard var result = img0 else {
            finish("AI Zoom gagal: \(note)")
            return
        }
        if let lut = burstLUT, let baked = RawDeveloper.applyLUT(to: result, lut) { result = baked }

        var props = properties
        props[kCGImageDestinationLossyCompressionQuality as String] = 0.92
        props.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        props.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else {
            finish("AI Zoom gagal encode")
            return
        }
        CGImageDestinationAddImage(dest, result, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            finish("AI Zoom gagal encode")
            return
        }
        let tz = Double(burstDisplayZoom)
        let prefix = burstAppleZoomAI ? "APPLEZOOM" : (burstMode == .aiZoom ? "AIZOOM"
            : (burstMode == .hdrplus ? (burstNight ? "MALAM_ZOOM" : "SUPERRES") : "CROPZOOM"))
        let mfTag = multiFrame > 0 ? "_MF\(multiFrame)" : ""
        let aiTag = note.hasPrefix("AI ") && !note.hasPrefix("AI gagal") ? "_AI\(burstSRModel == .detail ? "D" : "C")" : ""
        let name = String(format: "%@_%.1fx_%@%@%@_%@.heic", prefix, tz, burstLensName, mfTag, aiTag, res.label)
        save(out as Data, fileName: name, dir: dir)
        Log.sr.info("AI Zoom \(tz, privacy: .public)x lensa \(self.burstLensName, privacy: .public) crop \(Double(self.burstCrop), privacy: .public)x: sumber \(W, privacy: .public)x\(H, privacy: .public) -> \(result.width, privacy: .public)x\(result.height, privacy: .public), MF \(multiFrame, privacy: .public), \(note, privacy: .public)")
        let mfText = multiFrame > 0 ? " · MF \(multiFrame)" : ""
        let label = burstAppleZoomAI ? "Zoom Apple" : (burstMode == .aiZoom ? "AI Zoom"
            : (burstMode == .hdrplus ? "Super Res" : "Crop penuh"))
        finish(String(format: "%@ %.1fx · %@ crop %.1fx%@ · %@ -> %dx%d", label, tz, burstLensName,
                      Double(burstCrop), mfText, note, result.width, result.height))
    }

    /// zoom Apple + AI: hasil Apple (sudah diperbesar Apple) diperkecil ke detail aslinya
    /// (sisi panjang sensor / crop), lalu diperbesar lagi oleh AI ke resolusi output.
    private func processAppleZoomAI(_ photo: AVCapturePhoto, dir: URL?) {
        guard let cg0 = photo.cgImageRepresentation() else {
            finish("Zoom Apple + AI gagal: foto kosong")
            return
        }
        let long = max(cg0.width, cg0.height)
        let real = min(long, burstRealLong)
        let cg = real < long ? (SRUpscaler.resize(cg0, longSide: real) ?? cg0) : cg0
        Log.sr.info("Zoom Apple + AI: hasil Apple \(cg0.width, privacy: .public)x\(cg0.height, privacy: .public), detail asli ~\(real, privacy: .public) px sisi panjang")
        processAIZoomImage(cg, properties: photo.metadata, dir: dir, multiFrame: 0, cropOverride: 1)
    }

    // MARK: simpan
    private static func makeBurstDir(prefix: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bursts", isDirectory: true)
            .appendingPathComponent("\(prefix)_\(f.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func save(_ data: Data, fileName: String, dir: URL?) {
        if let dir {
            do { try data.write(to: dir.appendingPathComponent(fileName)) } catch {
                Log.camera.error("Tulis file gagal: \(String(describing: error), privacy: .public)")
            }
        }
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
        }) { ok, err in
            if !ok { Log.camera.error("Simpan ke Photos gagal: \(String(describing: err), privacy: .public)") }
        }
        rememberLast(data, fileName: fileName)
        // v0.13: AI Komposisi -> versi kedua yang diluruskan + di-crop rapi (foto asli tetap ada)
        let lower = fileName.lowercased()
        if compAI && compCrop && shootMode != .video && !lower.contains("_crop") && (lower.hasSuffix(".heic") || lower.hasSuffix(".jpg")) {
            DispatchQueue.global(qos: .utility).async {
                let t0 = CFAbsoluteTimeGetCurrent()
                guard let res = CompositionAI.cropVersion(data) else {
                    Log.camera.info("Komposisi: \(fileName, privacy: .public) sudah rapi, tanpa versi crop")
                    return
                }
                let base = (fileName as NSString).deletingPathExtension
                let dt = CFAbsoluteTimeGetCurrent() - t0
                Log.camera.info("Komposisi: \(base, privacy: .public)_CROP.heic (\(res.note, privacy: .public)) \(dt, format: .fixed(precision: 2), privacy: .public) s")
                self.save(res.data, fileName: base + "_CROP.heic", dir: dir)
                self.setStatus("AI Komposisi: versi crop disimpan (\(res.note))")
            }
        }
    }

    /// Live Photo: foto + video pasangan dalam satu aset
    private func saveLive(_ data: Data, movie: URL?, fileName: String, dir: URL?) {
        guard let movie else {
            save(data, fileName: fileName, dir: dir)
            return
        }
        if let dir { try? data.write(to: dir.appendingPathComponent(fileName)) }
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
            let opt = PHAssetResourceCreationOptions()
            opt.shouldMoveFile = true
            req.addResource(with: .pairedVideo, fileURL: movie, options: opt)
        }) { ok, err in
            if !ok { Log.camera.error("Simpan Live Photo gagal: \(String(describing: err), privacy: .public)") }
        }
        rememberLast(data, fileName: fileName + " (Live)")
    }

    /// thumbnail + data untuk penampil di app (hanya HEIC/JPEG)
    private func rememberLast(_ data: Data, fileName: String) {
        let lower = fileName.lowercased()
        guard lower.contains(".heic") || lower.contains(".jpg") else { return }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 240]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
        let thumb = UIImage(cgImage: t)
        DispatchQueue.main.async {
            self.lastThumb = thumb
            self.lastImageData = data
            self.lastFileName = fileName
        }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }
}

// MARK: - delegate foto
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            Log.camera.error("Capture error: \(String(describing: error), privacy: .public)")
            return
        }
        let md = photo.metadata["{Exif}"] as? [String: Any]
        let iso = (md?["ISOSpeedRatings"] as? [Any])?.first.map { "\($0)" } ?? "?"
        let exp = md?["ExposureTime"].map { "\($0)" } ?? "?"

        // Bayer untuk HDR+ / AI Zoom MF: salin data mentah sekarang
        var frame: BayerFrame?
        if collectsBayer, photo.isRawPhoto, let pb = photo.pixelBuffer {
            frame = merger?.makeFrame(from: pb)
        }
        sessionQueue.async {
            self.savedCount += 1
            let idx = self.savedCount
            let total = self.burstIndex + self.burstRemaining
            if self.collectsBayer {
                if let frame {
                    self.hdrFrames.append(frame)
                    if self.hdrRef == nil { self.hdrRef = photo }
                }
                if self.burstSaveFrames && self.burstMode == .hdrplus, let data = photo.fileDataRepresentation() {
                    self.save(data, fileName: String(format: "IMG_%04d.dng", idx), dir: self.burstDir)
                }
            } else if self.burstMode == .aiZoom || (self.burstZoomed && !photo.isRawPhoto) {
                let dir = self.burstDir
                self.processQueue.async { self.processAIZoom(photo, dir: dir) }
            } else if self.burstAppleZoomAI && !photo.isRawPhoto {
                let dir = self.burstDir
                self.processQueue.async { self.processAppleZoomAI(photo, dir: dir) }
            } else if var data = photo.fileDataRepresentation() {
                if !photo.isRawPhoto {
                    let longSide: Int? = self.burstOutputMP == .mp24 ? OutputMP.mp24.longSide : nil
                    if let re = RawDeveloper.reprocess(data, longSide: longSide, lut: self.burstLUT,
                                                       aspect: self.burstAspect) { data = re }
                }
                let name = String(format: "IMG_%04d.%@", idx, photo.isRawPhoto ? "dng" : "heic")
                if self.burstLive && !photo.isRawPhoto && photo.resolvedSettings.livePhotoMovieDimensions.width > 0 {
                    self.livePending = (data, name)      // disimpan bersama videonya di finishBurst
                } else {
                    self.save(data, fileName: name, dir: self.burstDir)
                }
            }
            if let pb = photo.pixelBuffer, idx == 1 {
                Log.camera.info("RAW buffer \(CVPixelBufferGetWidth(pb), privacy: .public)x\(CVPixelBufferGetHeight(pb), privacy: .public) format \(CVPixelBufferGetPixelFormatType(pb), privacy: .public)")
            }
            Log.camera.info("Frame \(idx, privacy: .public)/\(total, privacy: .public): raw=\(photo.isRawPhoto, privacy: .public) ISO \(iso, privacy: .public) exp \(exp, privacy: .public)")
            if total > 1 { self.setStatus("Burst \(idx)/\(total)") }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { Log.camera.error("Live Photo video gagal: \(String(describing: error), privacy: .public)") }
        let url: URL? = error == nil ? outputFileURL : nil
        sessionQueue.async { self.liveMovieURL = url }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { self.captureNext() }
    }
}

// MARK: - delegate video (preview)
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// antrean video (audio juga dikirim ke antrean ini supaya perekam aman satu thread)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        recorder?.appendVideo(pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if previewLog {
            // Apple Log: nilai mentah (tanpa manajemen warna) -> LUT Log -> Rec.709 untuk dilihat
            let raw = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
            logPreviewFilter.setValue(raw, forKey: kCIInputImageKey)
            let out = logPreviewFilter.outputImage ?? raw
            onFrame?(out.matchedToWorkingSpace(from: CGColorSpace(name: CGColorSpace.sRGB)!) ?? out)
        } else {
            onFrame?(CIImage(cvPixelBuffer: pb))
        }
    }
}

/// penyimpanan pengaturan sederhana (UserDefaults)
enum Prefs {
    private static let d = UserDefaults.standard
    static func get<T>(_ key: String, _ def: T) -> T { d.object(forKey: key) as? T ?? def }
    static func raw<E: RawRepresentable>(_ key: String, _ def: E) -> E {
        (d.object(forKey: key) as? E.RawValue).flatMap { E(rawValue: $0) } ?? def
    }
    static func set(_ key: String, _ value: Any) { d.set(value, forKey: key) }
}
