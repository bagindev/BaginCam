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
            case .hdrplus: return "Burst Bayer RAW -> align + merge di GPU (1 suara shutter), bisa zoom"
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
    @Published var burstCount = 8
    @Published var outputMP: OutputMP = .mp12       // resolusi output (HEIF, ProRAW, HDR+ HEIF/JPEG, AI Zoom)
    @Published var saveFrames = false               // HDR+: simpan juga frame mentah
    @Published var hdrNoiseReduction: Double = 18   // HDR+: 1..23
    @Published var outputFormat: PhotoFormat = .heif  // format simpan HDR+
    @Published var bakeLUT = false                  // bakar LUT aktif ke HEIF/JPEG
    /// LUT yang sedang dipilih (di-set dari UI); dipakai bila bakeLUT aktif
    var captureLUT: CubeLUT?

    // AI Zoom
    @Published private(set) var totalZoom: CGFloat = 1        // relatif lensa utama (1x = 24mm)
    @Published private(set) var maxTotalZoom: CGFloat = 25
    @Published private(set) var autoLensAvailable = false     // kamera virtual (pilih lensa otomatis)
    /// zoom minimum mode Auto (0.5 bila ada ultra wide)
    @Published private(set) var minAutoZoom: CGFloat = 1

    /// mode yang memakai kamera virtual (lensa otomatis seperti kamera bawaan): AI ZOOM & FOTO
    static func usesVirtual(_ m: Mode) -> Bool { m == .aiZoom || m == .heif }
    @Published var srModel: SRModel = .fast
    @Published var aiStrength: Double = 0.5                  // 0 = pembesaran biasa, 1 = AI penuh
    @Published var textFocus = true                           // AI Zoom: area tulisan pakai AI lebih kuat
    @Published var multiFrameZoom = true                      // burst Bayer + merge sebelum AI (bila tersedia)

    @Published private(set) var isCapturing = false
    /// progres pemrosesan berat (0..1), nil = tidak ada
    @Published private(set) var progress: Double?
    /// zoom di FOTO/HDR+: pakai AI (true) atau pembesaran biasa Lanczos (false) - untuk membandingkan
    @Published var zoomAIEnabled = true
    /// zoom preview tambahan di luar batas zoom hardware (dipakai renderer)
    @Published private(set) var previewExtraZoom: CGFloat = 1
    /// fokus/eksposur dikunci (tekan lama di preview)
    @Published private(set) var aeafLocked = false
    /// AI Zoom: kunci lensa fisik (nil = Auto, iOS memilih seperti kamera bawaan)
    @Published private(set) var aiLensLock: Lens?
    /// kompensasi eksposur (EV) saat mode Auto
    @Published private(set) var evBias: Float = 0
    @Published var mergeMethod: MergeMethod = .frequency
    @Published var autoFrames = true                 // HDR+: jumlah frame menurut kecerahan
    @Published private(set) var wbPreset: WBPreset = .auto
    @Published var timerSeconds = 0                  // 0 / 3 / 10
    @Published private(set) var countdown = 0        // sisa hitungan timer (0 = tidak berjalan)
    /// preview dibekukan saat capture (zoom/lensa diganti di belakang layar)
    @Published private(set) var previewFrozen = false
    @Published private(set) var progressText = ""
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
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
        let mode = self.mode, lens = self.lens
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { self.setStatus("Izin kamera ditolak"); return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
            self.sessionQueue.async {
                if !self.configured { self.configure(mode: mode, lens: lens) }
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
        if mode == .aiZoom { enterAIZoom() } else {
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
        if let maxDims = maxDimensions(of: d) { photoOutput.maxPhotoDimensions = maxDims }
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()
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
    }

    /// AI Zoom: kunci ke lensa fisik (Utama / Tele) atau Auto (nil). Panggil dari main thread.
    func setAILensLock(_ l: Lens?) {
        guard Self.usesVirtual(mode), !isCapturing, l != aiLensLock else { return }
        aiLensLock = l
        aeafLocked = false
        let native: CGFloat = l == .tele ? 5 : (l == .ultraWide ? 0.5 : 1)
        let tz = max(totalZoom, l == nil ? 1 : native)
        sessionQueue.async {
            guard let l else { self.enterAIZoom(zoom: tz); return }
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
        let zz = min(max(minZ, z), maxTotalZoom)
        totalZoom = zz
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            let base = self.isVirtual ? self.wideBase : (self.aiLockNative > 0 ? 1 / self.aiLockNative : 1)
            let want = zz * base
            let applied = min(max(want, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            d.videoZoomFactor = applied
            d.unlockForConfiguration()
            let extra = max(1, want / applied)
            DispatchQueue.main.async { self.previewExtraZoom = extra }
        }
    }

    // MARK: sentuh untuk fokus
    /// `p`: titik di preview potret, 0..1. Tekan lama (`lock`) = kunci AE/AF di titik itu.
    func focus(atViewPoint p: CGPoint, lock: Bool) {
        guard isAuto, !isCapturing else { return }
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
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = pt
                d.focusMode = .autoFocus
            }
            if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
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
    func setAuto(_ auto: Bool) {
        isAuto = auto
        if auto {
            sessionQueue.async { self.applyAuto() }
        } else {
            iso = liveISO > 0 ? liveISO : iso
            shutter = liveShutter > 0 ? liveShutter : shutter
            temperature = liveTemp > 0 ? liveTemp : temperature
            lensPosition = liveLens
            applyManual()
        }
    }

    private func applyAuto() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        applyWB(d)
        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        d.setExposureTargetBias(min(max(evBiasSession, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
        d.unlockForConfiguration()
    }

    /// Kirim nilai slider manual ke kamera.
    func applyManual() {
        let iso = self.iso, shutter = self.shutter, temp = self.temperature, lens = self.lensPosition
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            let fmt = d.activeFormat
            let s = min(max(shutter, fmt.minExposureDuration.seconds), fmt.maxExposureDuration.seconds)
            let i = min(max(iso, fmt.minISO), fmt.maxISO)
            if d.isExposureModeSupported(.custom) {
                d.setExposureModeCustom(duration: CMTime(seconds: s, preferredTimescale: 1_000_000_000),
                                        iso: i, completionHandler: nil)
            }
            if d.isWhiteBalanceModeSupported(.locked), d.maxWhiteBalanceGain >= 1 {
                let tv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: min(max(temp, 2500), 9000), tint: 0)
                d.setWhiteBalanceModeLocked(with: Self.clamp(d.deviceWhiteBalanceGains(for: tv), d.maxWhiteBalanceGain),
                                            completionHandler: nil)
            }
            if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: min(max(lens, 0), 1), completionHandler: nil)
            }
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
        liveISO = d.iso
        liveShutter = d.exposureDuration.seconds
        liveLens = d.lensPosition
        activeLensLabel = lensLabel(for: d)
        let maxGain = d.maxWhiteBalanceGain
        let g = d.deviceWhiteBalanceGains
        guard maxGain >= 1, g.redGain > 0, g.greenGain > 0, g.blueGain > 0 else { return }
        liveTemp = d.temperatureAndTintValues(for: Self.clamp(g, maxGain)).temperature
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

    // MARK: capture
    /// Tombol shutter / tombol volume: pakai timer bila diatur.
    func shutterPressed() {
        guard !isCapturing, countdown == 0 else { return }
        guard timerSeconds > 0 else { startBurst(); return }
        countdown = timerSeconds
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard self.countdown > 0 else { return }
                self.countdown -= 1
                if self.countdown == 0 { self.startBurst() } else { tick() }
            }
        }
        tick()
    }

    func cancelCountdown() { countdown = 0 }

    /// jumlah frame HDR+ menurut kecerahan (ISO x waktu eksposur saat ini)
    private func autoFrameCount() -> Int {
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
        isCapturing = true
        previewFrozen = true
        // proses tetap jalan sebentar bila app ditinggal (iOS memberi ~30 detik)
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BaginCam processing") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        let m = mode
        let count = m == .heif ? 1 : (m == .hdrplus && autoFrames ? autoFrameCount() : max(m == .hdrplus ? 2 : 1, burstCount))
        let merge = mergeMethod
        let useAI = zoomAIEnabled
        let lensNative: CGFloat = lens == .tele ? 5 : (lens == .ultraWide ? 0.5 : 1)
        let auto = isAuto, keep = saveFrames, nr = hdrNoiseReduction, res = outputMP
        let fmt = outputFormat, lut = bakeLUT ? captureLUT : nil
        let tz = totalZoom, model = srModel, strength = aiStrength, mf = multiFrameZoom, tf = textFocus
        sessionQueue.async {
            self.burstAuto = auto
            self.burstMode = m
            self.burstSaveFrames = keep
            self.burstNR = nr
            self.burstMerge = merge
            self.burstOutputMP = res
            self.burstFormat = fmt
            self.burstLUT = lut
            self.burstTotalZoom = tz
            self.burstSRModel = model
            self.burstStrength = (m == .aiZoom || useAI) ? strength : 0
            self.restoreZoomAfterBurst = false
            self.burstTextFocus = tf
            self.burstZoomed = m == .aiZoom
            self.burstDisplayZoom = m == .aiZoom ? tz : tz * lensNative
            // orientasi foto mengikuti cara HP dipegang (potret/lanskap)
            if let rc = self.rotationCoordinator, let c = self.photoOutput.connection(with: .video) {
                let a = rc.videoRotationAngleForHorizonLevelCapture
                if c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
            }
            var frames = count
            var delay = m.isBurst ? 0.15 : 0.0
            if m == .hdrplus && tz > 1.01 {
                // zoom di FOTO / HDR+: ambil resolusi penuh (zoom hardware 1x), crop + upscale sendiri
                if let d = self.device, (try? d.lockForConfiguration()) != nil {
                    d.videoZoomFactor = 1
                    d.unlockForConfiguration()
                }
                self.restoreZoomAfterBurst = true
                self.burstZoomed = true
                self.burstCrop = tz
                self.burstLensName = self.lens.displayName
                self.burstAIFull = true
                self.burstAIMultiFrame = false
                delay = max(delay, 0.3)
            }
            // FOTO: tanpa AI (atau zoom masih optik) = proses Apple apa adanya seperti kamera bawaan.
            var fotoAI = false
            if m == .heif && useAI {
                var base: CGFloat = self.aiLockNative > 0 ? self.aiLockNative : 1
                var z = tz
                if let d = self.device, d.isVirtualDevice, let p = d.activePrimaryConstituent {
                    base = self.lensBase[p.deviceType] ?? 1
                    z = tz * self.wideBase
                }
                fotoAI = z / base > 1.05     // ada zoom digital di atas lensa optik
            }
            if m == .aiZoom || fotoAI {
                self.burstZoomed = true
                // Lensa dipilih iOS (kamera virtual: tele vs crop lensa utama). Untuk memotret, pindah
                // sementara ke lensa FISIK itu: kamera virtual hanya memberi 12MP & tanpa Bayer RAW
                // (log v0.6.0: lensa utama crop 10x -> sumber cuma 4032x3024).
                var base: CGFloat = 1
                var lensName = self.lens.displayName
                let virtualWide = self.isVirtual ? self.wideBase : 1
                if let d = self.device, d.isVirtualDevice, let p = d.activePrimaryConstituent {
                    base = self.lensBase[p.deviceType] ?? 1
                    lensName = Self.name(of: p.deviceType)
                    self.install(p, mirrored: false)
                    self.isVirtual = false
                    self.applyRawMode(.aiZoom)
                    self.applyAuto()
                    self.switchedToPhysicalForMF = true
                    delay = 0.9   // beri waktu AE/AF/AWB lensa fisik stabil
                    Log.camera.info("AI Zoom: pindah ke lensa fisik \(p.localizedName, privacy: .public)")
                } else if let d = self.device, (try? d.lockForConfiguration()) != nil {
                    // lensa dikunci (atau tanpa kamera virtual): sudah lensa fisik, cukup zoom 1x
                    d.videoZoomFactor = 1
                    d.unlockForConfiguration()
                    if self.aiLockNative > 0 {
                        base = self.aiLockNative
                        lensName = self.aiLockNative >= 2 ? "Tele" : (self.aiLockNative < 0.9 ? "Ultra Wide" : "Utama")
                    }
                    self.restoreZoomAfterBurst = true
                    delay = 0.3
                }
                self.burstCrop = max(1, tz * virtualWide / base)
                self.burstLensName = lensName
                let bayer = self.photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
                // multi-frame: lensa tele, atau crop >= 3x di lensa utama (48MP tunggal kalah oleh merge 8 frame)
                self.burstAIMultiFrame = m == .aiZoom && mf && bayer && (lensName == "Tele" || self.burstCrop >= 3)
                self.burstAIFull = !self.burstAIMultiFrame
                frames = self.burstAIMultiFrame ? 8 : 1
            }
            self.burstRemaining = frames
            self.burstIndex = 0
            self.savedCount = 0
            self.hdrFrames = []
            self.hdrRef = nil
            self.burstDir = Self.makeBurstDir(prefix: m == .hdrplus ? "HDRPLUS" : m == .aiZoom ? "AIZOOM" : (m == .heif ? "FOTO" : "BURST"))
            let isMulti = m.isBurst || self.burstAIMultiFrame
            Log.camera.info("Capture mulai: \(frames, privacy: .public) frame, mode \(m.rawValue, privacy: .public), zoom total \(Double(tz), privacy: .public)x, lensa \(self.burstLensName, privacy: .public), crop \(Double(self.burstCrop), privacy: .public)x, MF \(self.burstAIMultiFrame, privacy: .public)")
            self.setStatus(isMulti ? "Burst 0/\(frames)" : "Memotret...")
            // kunci AE/AWB/AF SETELAH lensa stabil, lalu mulai capture
            self.sessionQueue.asyncAfter(deadline: .now() + delay) {
                if auto && isMulti { self.lockCurrent() }
                self.sessionQueue.asyncAfter(deadline: .now() + (auto && isMulti ? 0.15 : 0)) { self.captureNext() }
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
        let n = burstIndex, dir = burstDir
        DispatchQueue.main.async { self.previewFrozen = false }
        Log.camera.info("Capture selesai: \(n, privacy: .public) frame -> \(dir?.lastPathComponent ?? "-", privacy: .public)")
        if collectsBayer {
            let frames = hdrFrames, ref = hdrRef, nr = burstNR, ai = burstMode == .aiZoom
            hdrFrames = []
            hdrRef = nil
            processQueue.async { self.processHDRPlus(frames: frames, ref: ref, dir: dir, noiseReduction: nr, forAIZoom: ai) }
        } else if !burstZoomed {
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
        // burst: hanya frame pertama yang berbunyi (bila iOS / wilayah mengizinkan)
        if #available(iOS 18.0, *), burstIndex > 1, photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }

        // resolusi: HEIF/ProRAW 24/48MP -> sensor penuh; AI Zoom lensa utama -> penuh; Bayer ~12MP
        if let d = device {
            let full = maxDimensions(of: d), std = standardDimensions(of: d)
            let wantFull = !wantBayer && ((m == .aiZoom && burstAIFull) || (m == .heif && burstZoomed)
                                          || (burstOutputMP != .mp12 && (m == .heif || m == .proraw)))
            if let dims = wantFull ? full : std,
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
            let boxes = TextBoost.textBoxes(in: upT)
            if !boxes.isEmpty, let comp = TextBoost.compose(plain: plain, ai: upT, strength: strength,
                                                             textStrength: max(strength, 0.95), boxes: boxes) {
                Log.sr.info("Fokus tulisan: \(boxes.count, privacy: .public) area teks")
                return (comp, "AI \(model.rawValue) \(Int((strength * 100).rounded()))% + teks \(boxes.count)")
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
            guard let img = RawDeveloper.develop(dng: dng, highlight: highlight), let cg = RawDeveloper.cgImage(img) else {
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
            if var img = RawDeveloper.develop(dng: dng, highlight: highlight) {
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
                    save(data, fileName: "HDRPLUS_\(frames.count)f_\(res.label)\(lut != nil ? "_LUT" : "").\(ext)", dir: dir)
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
    private func processAIZoomImage(_ cg: CGImage, properties: [String: Any], dir: URL?, multiFrame: Int) {
        let W = cg.width, H = cg.height
        let c = max(1, Double(burstCrop))
        let cw = max(16, Int(Double(W) / c)) & ~1, ch = max(16, Int(Double(H) / c)) & ~1
        let rect = CGRect(x: (W - cw) / 2, y: (H - ch) / 2, width: cw, height: ch)
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
        let prefix = burstMode == .aiZoom ? "AIZOOM" : (burstMode == .hdrplus ? "HDRPLUS_ZOOM" : "FOTO_ZOOM")
        let mfTag = multiFrame > 0 ? "_MF\(multiFrame)" : ""
        let aiTag = note.hasPrefix("AI ") && !note.hasPrefix("AI gagal") ? "_AI\(burstSRModel == .detail ? "D" : "C")" : ""
        let name = String(format: "%@_%.1fx_%@%@%@_%@.heic", prefix, tz, burstLensName, mfTag, aiTag, res.label)
        save(out as Data, fileName: name, dir: dir)
        Log.sr.info("AI Zoom \(tz, privacy: .public)x lensa \(self.burstLensName, privacy: .public) crop \(Double(self.burstCrop), privacy: .public)x: sumber \(W, privacy: .public)x\(H, privacy: .public) -> \(result.width, privacy: .public)x\(result.height, privacy: .public), MF \(multiFrame, privacy: .public), \(note, privacy: .public)")
        let mfText = multiFrame > 0 ? " · MF \(multiFrame)" : ""
        let label = burstMode == .aiZoom ? "AI Zoom" : (burstMode == .hdrplus ? "HDR+ zoom" : "Foto zoom")
        finish(String(format: "%@ %.1fx · %@ crop %.1fx%@ · %@ -> %dx%d", label, tz, burstLensName,
                      Double(burstCrop), mfText, note, result.width, result.height))
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
            } else if var data = photo.fileDataRepresentation() {
                if !photo.isRawPhoto {
                    let longSide: Int? = self.burstOutputMP == .mp24 ? OutputMP.mp24.longSide : nil
                    if let re = RawDeveloper.reprocess(data, longSide: longSide, lut: self.burstLUT) { data = re }
                }
                self.save(data, fileName: String(format: "IMG_%04d.%@", idx, photo.isRawPhoto ? "dng" : "heic"),
                          dir: self.burstDir)
            }
            if let pb = photo.pixelBuffer, idx == 1 {
                Log.camera.info("RAW buffer \(CVPixelBufferGetWidth(pb), privacy: .public)x\(CVPixelBufferGetHeight(pb), privacy: .public) format \(CVPixelBufferGetPixelFormatType(pb), privacy: .public)")
            }
            Log.camera.info("Frame \(idx, privacy: .public)/\(total, privacy: .public): raw=\(photo.isRawPhoto, privacy: .public) ISO \(iso, privacy: .public) exp \(exp, privacy: .public)")
            if total > 1 { self.setStatus("Burst \(idx)/\(total)") }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { self.captureNext() }
    }
}

// MARK: - delegate video (preview)
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(CIImage(cvPixelBuffer: pb))
    }
}
