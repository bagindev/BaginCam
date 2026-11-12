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
        var isBurst: Bool { self != .aiZoom }
        var detail: String {
            switch self {
            case .hdrplus: return "Burst Bayer RAW -> align + merge di GPU -> 1 DNG"
            case .bayer: return "Burst Bayer RAW (untuk pc-lab)"
            case .proraw: return "Burst Apple ProRAW"
            case .heif: return "Burst HEIF"
            case .aiZoom: return "1 foto resolusi penuh -> crop -> super-resolution x4"
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

    @Published private(set) var mode: Mode = .hdrplus
    @Published private(set) var lens: Lens = .wide
    @Published private(set) var availableLenses: [Lens] = [.wide]
    @Published var zoom: CGFloat = 1              // AI Zoom (digital, 1..10x)
    @Published var burstCount = 8
    @Published var use48MP = false                // HEIF / ProRAW resolusi penuh
    @Published var saveFrames = false             // HDR+: simpan juga frame mentah
    @Published var hdrNoiseReduction: Double = 18 // HDR+: 1..23
    @Published var outputFormat: PhotoFormat = .heif  // format simpan HDR+
    @Published var bakeLUT = false                // bakar LUT aktif ke HEIF/JPEG (HDR+, HEIF, AI Zoom)
    /// LUT yang sedang dipilih (di-set dari UI); dipakai bila bakeLUT aktif
    var captureLUT: CubeLUT?
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Menyiapkan kamera..."
    @Published private(set) var supportsBayer = false
    @Published private(set) var supportsProRAW = false
    @Published private(set) var maxMP = 12
    @Published private(set) var srAvailable = SRUpscaler.isBundled

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

    // burst (diakses di sessionQueue)
    private var burstRemaining = 0
    private var burstIndex = 0
    private var burstAuto = true
    private var burstMode: Mode = .hdrplus
    private var burstDir: URL?
    private var burstZoom: CGFloat = 1
    private var burstSaveFrames = false
    private var burstNR: Double = 18
    private var burstUse48 = false
    private var burstFormat: PhotoFormat = .heif
    private var burstLUT: CubeLUT?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var savedCount = 0
    private var hdrFrames: [BayerFrame] = []
    private var hdrRef: AVCapturePhoto?

    // engine (dibuat di sessionQueue / processQueue)
    private var merger: HDRPlusMerger?
    private var upscaler: SRUpscaler?
    private var upscalerTried = false

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
        DispatchQueue.main.async { self.availableLenses = lenses }
        switchDevice(to: lenses.contains(lens) ? lens : (lenses.first ?? .wide), mode: mode)
    }

    // MARK: lensa
    func setLens(_ l: Lens) {
        guard !isCapturing, l != lens else { return }
        lens = l
        zoom = 1
        isAuto = true
        let m = mode
        sessionQueue.async { self.switchDevice(to: l, mode: m) }
    }

    private func switchDevice(to l: Lens, mode: Mode) {
        guard let d = AVCaptureDevice.default(l.deviceType, for: .video, position: l.position),
              let input = try? AVCaptureDeviceInput(device: d) else {
            setStatus("Lensa \(l.rawValue) tidak tersedia")
            return
        }
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
            // kamera depan: preview & foto dicerminkan (seperti kamera bawaan)
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = l == .front
            }
        }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil)
        // resolusi foto maksimum lensa ini (48MP di lensa utama / ultra wide)
        if let maxDims = maxDimensions(of: d) { photoOutput.maxPhotoDimensions = maxDims }
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()

        applyRawMode(mode)
        applyAuto()
        publishCapabilities(d, lens: l, mode: mode)
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

    private func publishCapabilities(_ d: AVCaptureDevice, lens l: Lens, mode: Mode) {
        let fmt = d.activeFormat
        let minS = max(fmt.minExposureDuration.seconds, 1.0 / 8000)
        let maxS = max(min(fmt.maxExposureDuration.seconds, 1.0), minS * 2)
        let bayer = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
            || photoOutput.isAppleProRAWEnabled   // saat ProRAW aktif, daftar Bayer disembunyikan
        let pro = photoOutput.isAppleProRAWSupported
        let mp = maxDimensions(of: d).map { Int($0.width) * Int($0.height) / 1_000_000 } ?? 12
        Log.camera.info("Lensa \(l.rawValue, privacy: .public): ISO \(fmt.minISO, privacy: .public)-\(fmt.maxISO, privacy: .public), shutter \(minS, privacy: .public)-\(maxS, privacy: .public)s, Bayer \(bayer, privacy: .public), ProRAW \(pro, privacy: .public), maks \(mp, privacy: .public)MP")
        DispatchQueue.main.async {
            self.isoRange = fmt.minISO...fmt.maxISO
            self.shutterRange = minS...maxS
            self.supportsBayer = bayer
            self.supportsProRAW = pro
            self.maxMP = mp
            if (mode.usesBayer && !bayer) || (mode == .proraw && !pro) {
                self.setMode(.heif)
                self.status = "Lensa \(l.rawValue) tidak mendukung \(mode.rawValue) -> HEIF"
            }
        }
    }

    // MARK: mode
    func setMode(_ m: Mode) {
        guard !isCapturing else { return }
        mode = m
        if m != .aiZoom { zoom = 1 }
        sessionQueue.async { self.applyRawMode(m) }
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
            // mulai mode manual dari nilai yang sedang dipakai auto
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
        if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
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
        if d.isWhiteBalanceModeSupported(.locked) {
            d.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
        }
        if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
        d.unlockForConfiguration()
    }

    /// Baca nilai kamera untuk ditampilkan.
    /// PENTING: API white balance AVFoundation melempar NSException (crash, tidak bisa di-catch Swift)
    /// bila gain di luar [1, maxWhiteBalanceGain] - mis. gain 0 sebelum session jalan (bug v0.1.0).
    private func updateReadout() {
        guard let d = device, session.isRunning else { return }
        liveISO = d.iso
        liveShutter = d.exposureDuration.seconds
        liveLens = d.lensPosition
        let maxGain = d.maxWhiteBalanceGain
        let g = d.deviceWhiteBalanceGains
        guard maxGain >= 1, g.redGain > 0, g.greenGain > 0, g.blueGain > 0 else { return }
        liveTemp = d.temperatureAndTintValues(for: Self.clamp(g, maxGain)).temperature
    }

    // MARK: capture
    func startBurst() {
        guard !isCapturing else { return }
        if mode == .aiZoom && !srAvailable && zoom > 1.01 {
            status = "Model AI Zoom belum ada di build ini"
        }
        isCapturing = true
        let m = mode
        let count = m == .aiZoom ? 1 : max(m == .hdrplus ? 2 : 1, burstCount)
        let auto = isAuto, z = zoom, keep = saveFrames, nr = hdrNoiseReduction, big = use48MP
        let fmt = outputFormat, lut = bakeLUT ? captureLUT : nil
        sessionQueue.async {
            self.burstAuto = auto
            self.burstMode = m
            self.burstZoom = z
            self.burstSaveFrames = keep
            self.burstNR = nr
            self.burstUse48 = big
            self.burstFormat = fmt
            self.burstLUT = lut
            // orientasi foto mengikuti cara HP dipegang (potret/lanskap)
            if let rc = self.rotationCoordinator, let c = self.photoOutput.connection(with: .video) {
                let a = rc.videoRotationAngleForHorizonLevelCapture
                if c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
            }
            self.burstRemaining = count
            self.burstIndex = 0
            self.savedCount = 0
            self.hdrFrames = []
            self.hdrRef = nil
            self.burstDir = Self.makeBurstDir(prefix: m == .hdrplus ? "HDRPLUS" : m == .aiZoom ? "AIZOOM" : "BURST")
            if auto && m.isBurst { self.lockCurrent() }
            Log.camera.info("Capture mulai: \(count, privacy: .public) frame, mode \(m.rawValue, privacy: .public), zoom \(Double(z), privacy: .public)")
            self.setStatus(m.isBurst ? "Burst 0/\(count)" : "Memotret...")
            // beri waktu kunci AE/AWB/AF stabil
            self.sessionQueue.asyncAfter(deadline: .now() + (m.isBurst ? 0.15 : 0.0)) { self.captureNext() }
        }
    }

    private func captureNext() {
        guard burstRemaining > 0 else { finishBurst(); return }
        burstRemaining -= 1
        burstIndex += 1
        photoOutput.capturePhoto(with: makeSettings(burstMode), delegate: self)
    }

    private func finishBurst() {
        if burstAuto && burstMode.isBurst { applyAuto() }
        let n = burstIndex, dir = burstDir
        Log.camera.info("Capture selesai: \(n, privacy: .public) frame -> \(dir?.lastPathComponent ?? "-", privacy: .public)")
        switch burstMode {
        case .hdrplus:
            let frames = hdrFrames, ref = hdrRef, nr = burstNR
            hdrFrames = []
            hdrRef = nil
            processQueue.async { self.processHDRPlus(frames: frames, ref: ref, dir: dir, noiseReduction: nr) }
        case .aiZoom:
            break   // selesai di processAIZoom
        default:
            finish("Tersimpan \(n) frame (\(dir?.lastPathComponent ?? "-"))")
        }
    }

    private func finish(_ message: String) {
        DispatchQueue.main.async {
            self.isCapturing = false
            self.status = message
        }
    }

    private func makeSettings(_ m: Mode) -> AVCapturePhotoSettings {
        let raws = photoOutput.availableRawPhotoPixelFormatTypes
        var s: AVCapturePhotoSettings?
        switch m {
        case .bayer, .hdrplus:
            if let fmt = raws.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
                s = AVCapturePhotoSettings(rawPixelFormatType: fmt)
                s?.photoQualityPrioritization = .speed
            }
        case .proraw:
            if let fmt = raws.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                s = AVCapturePhotoSettings(rawPixelFormatType: fmt)
                s?.photoQualityPrioritization = .quality
            }
        case .heif, .aiZoom:
            break
        }
        let settings = s ?? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        if s == nil { settings.photoQualityPrioritization = m == .aiZoom ? .quality : .balanced }

        // resolusi: AI Zoom selalu maksimum; HEIF/ProRAW maksimum bila 48MP aktif; Bayer ~12MP
        if let d = device {
            let full = maxDimensions(of: d), std = standardDimensions(of: d)
            let wantFull = m == .aiZoom || (burstUse48 && (m == .heif || m == .proraw))
            if let dims = wantFull ? full : std,
               Int(dims.width) * Int(dims.height) <= Int(photoOutput.maxPhotoDimensions.width) * Int(photoOutput.maxPhotoDimensions.height) {
                settings.maxPhotoDimensions = dims
            }
        }
        return settings
    }

    // MARK: HDR+
    private func processHDRPlus(frames: [BayerFrame], ref: AVCapturePhoto?, dir: URL?, noiseReduction: Double) {
        guard let ref, let refPB = ref.pixelBuffer, let merger = self.merger, frames.count >= 2 else {
            Log.hdr.error("HDR+ batal: frame \(frames.count, privacy: .public), ref \(ref != nil, privacy: .public)")
            finish("HDR+ gagal: frame Bayer tidak lengkap (\(frames.count))")
            return
        }
        setStatus("Memproses HDR+ \(frames.count) frame...")
        guard let r = merger.merge(frames, noiseReduction: noiseReduction, progress: { i, n in
            self.setStatus("Memproses HDR+ \(i)/\(n)...")
        }) else {
            finish("HDR+ gagal saat merge (lihat log)")
            return
        }
        // tulis DNG sendiri (replacementRawPixelBuffer diabaikan iOS untuk Bayer - bug v0.4.0)
        guard let refDNG = ref.fileDataRepresentation() else {
            finish("HDR+ gagal: DNG referensi kosong")
            return
        }
        let px = r.buffer.contents().bindMemory(to: UInt16.self, capacity: r.width * r.height)
        let dng: Data
        do {
            dng = try DNGWriter.rewrite(original: refDNG, pixels: px, width: r.width, height: r.height,
                                        software: "BaginCam HDR+ \(frames.count) frame")
        } catch {
            Log.hdr.error("Tulis DNG gagal: \(String(describing: error), privacy: .public)")
            finish("HDR+ gagal menulis DNG: \(error)")
            return
        }
        let fmt = burstFormat, lut = burstLUT
        var saved: [String] = []
        if fmt.wantsDNG {
            save(dng, fileName: "HDRPLUS_\(frames.count)f.dng", dir: dir)
            saved.append("DNG")
        }
        if fmt.wantsHEIF || fmt.wantsJPEG {
            setStatus("HDR+: mengembangkan RAW...")
            var rendered = false
            if let img = RawDeveloper.develop(dng: dng) {
                let final = RawDeveloper.applyLUT(img, lut)
                if let data = fmt.wantsJPEG ? RawDeveloper.encodeJPEG(final) : RawDeveloper.encodeHEIF(final) {
                    let ext = fmt.wantsJPEG ? "jpg" : "heic"
                    save(data, fileName: "HDRPLUS_\(frames.count)f\(lut != nil ? "_LUT" : "").\(ext)", dir: dir)
                    saved.append(ext.uppercased())
                    rendered = true
                }
            }
            if !rendered && !fmt.wantsDNG {
                // render gagal -> jangan hilangkan hasil: simpan DNG
                save(dng, fileName: "HDRPLUS_\(frames.count)f.dng", dir: dir)
                saved.append("DNG (render HEIF/JPEG gagal)")
            }
        }
        let w = r.meanWeights.isEmpty ? 0 : r.meanWeights.reduce(0, +) / Float(r.meanWeights.count)
        finish(String(format: "HDR+ %d frame %.1f s, bobot %.2f -> %@", frames.count, r.seconds, w,
                      saved.joined(separator: " + ")))
    }

    // MARK: AI Zoom
    private func processAIZoom(_ photo: AVCapturePhoto, zoom: CGFloat, dir: URL?) {
        guard let cg = photo.cgImageRepresentation() else {
            finish("AI Zoom gagal: foto kosong")
            return
        }
        let W = cg.width, H = cg.height
        let z = max(1, zoom)
        let cw = max(2, Int(Double(W) / Double(z))) & ~1, ch = max(2, Int(Double(H) / Double(z))) & ~1
        guard let crop = cg.cropping(to: CGRect(x: (W - cw) / 2, y: (H - ch) / 2, width: cw, height: ch)) else {
            finish("AI Zoom gagal crop")
            return
        }
        let target = 4032
        var result = crop
        var usedSR = false
        var srError: String?
        if max(cw, ch) < target {
            if !upscalerTried { upscaler = SRUpscaler(); upscalerTried = true }
            if let sr = upscaler {
                setStatus("AI Zoom: super-resolution...")
                if let up = sr.upscale(crop, progress: { d, n in
                    if d % 4 == 0 || d == n { self.setStatus("AI Zoom \(d)/\(n) tile...") }
                }) {
                    result = SRUpscaler.resize(up, longSide: min(max(cw, ch) * SRUpscaler.scale, target)) ?? up
                    usedSR = true
                } else {
                    srError = sr.lastError ?? "prediksi gagal"
                }
            } else {
                srError = "model tidak bisa dimuat"
            }
            if !usedSR {
                // jangan simpan potongan kecil: perbesar biasa ke 12MP
                result = SRUpscaler.resize(crop, longSide: target) ?? crop
            }
        }
        if let lut = burstLUT, let baked = RawDeveloper.applyLUT(to: result, lut) { result = baked }
        // simpan HEIC dengan metadata asli (orientasi, EXIF)
        var props = photo.metadata
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
        let name = String(format: "AIZOOM_%.1fx%@.heic", Double(z), usedSR ? "_SR" : "")
        save(out as Data, fileName: name, dir: dir)
        Log.sr.info("AI Zoom \(Double(z), privacy: .public)x: sumber \(W, privacy: .public)x\(H, privacy: .public), crop \(cw, privacy: .public)x\(ch, privacy: .public) -> \(result.width, privacy: .public)x\(result.height, privacy: .public), SR \(usedSR, privacy: .public)")
        if let srError {
            Log.sr.error("AI Zoom tanpa SR: \(srError, privacy: .public)")
            finish(String(format: "AI Zoom %.1fx -> %dx%d (AI gagal: %@)", Double(z), result.width, result.height, srError))
        } else {
            finish(String(format: "AI Zoom %.1fx -> %dx%d%@", Double(z), result.width, result.height, usedSR ? " (AI)" : ""))
        }
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

        // Bayer untuk HDR+: salin data mentah sekarang (buffer AVFoundation tidak ditahan lama)
        var frame: BayerFrame?
        if burstModeSnapshot == .hdrplus, photo.isRawPhoto, let pb = photo.pixelBuffer {
            frame = merger?.makeFrame(from: pb)
        }
        sessionQueue.async {
            self.savedCount += 1
            let idx = self.savedCount
            let total = self.burstIndex + self.burstRemaining
            switch self.burstMode {
            case .hdrplus:
                if let frame {
                    self.hdrFrames.append(frame)
                    if self.hdrRef == nil { self.hdrRef = photo }
                }
                if self.burstSaveFrames, let data = photo.fileDataRepresentation() {
                    self.save(data, fileName: String(format: "IMG_%04d.dng", idx), dir: self.burstDir)
                }
            case .aiZoom:
                let z = self.burstZoom, dir = self.burstDir
                self.processQueue.async { self.processAIZoom(photo, zoom: z, dir: dir) }
            default:
                if var data = photo.fileDataRepresentation() {
                    if !photo.isRawPhoto, let lut = self.burstLUT, let baked = RawDeveloper.bakeLUT(into: data, lut: lut) {
                        data = baked
                    }
                    self.save(data, fileName: String(format: "IMG_%04d.%@", idx, photo.isRawPhoto ? "dng" : "heic"),
                              dir: self.burstDir)
                }
            }
            if let pb = photo.pixelBuffer, idx == 1 {
                Log.camera.info("RAW buffer \(CVPixelBufferGetWidth(pb), privacy: .public)x\(CVPixelBufferGetHeight(pb), privacy: .public) format \(CVPixelBufferGetPixelFormatType(pb), privacy: .public)")
            }
            Log.camera.info("Frame \(idx, privacy: .public)/\(total, privacy: .public): raw=\(photo.isRawPhoto, privacy: .public) ISO \(iso, privacy: .public) exp \(exp, privacy: .public)")
            if self.burstMode.isBurst { self.setStatus("Burst \(idx)/\(total)") }
        }
    }

    /// burstMode di-set di sessionQueue sebelum capture dimulai -> aman dibaca (tidak berubah selama burst)
    private var burstModeSnapshot: Mode { burstMode }

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
