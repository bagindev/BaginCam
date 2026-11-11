import AVFoundation
import CoreImage
import Photos
import UIKit

/// Semua akses AVCaptureSession / device dilakukan di `sessionQueue`.
/// Properti @Published hanya diubah di main thread.
final class CameraManager: NSObject, ObservableObject {

    enum RawMode: String, CaseIterable, Identifiable {
        case bayer = "Bayer RAW"
        case proraw = "ProRAW"
        case heif = "HEIF"
        var id: String { rawValue }
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

    @Published var rawMode: RawMode = .bayer
    @Published var burstCount = 8
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Menyiapkan kamera..."
    @Published private(set) var supportsBayer = false
    @Published private(set) var supportsProRAW = false

    /// Dipanggil di antrean video untuk tiap frame preview.
    var onFrame: ((CIImage) -> Void)?

    // MARK: AVFoundation
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "modkamera.session")
    private let videoQueue = DispatchQueue(label: "modkamera.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var readoutTimer: Timer?

    // burst
    private var burstRemaining = 0
    private var burstIndex = 0
    private var burstAuto = true
    private var burstMode: RawMode = .bayer
    private var burstDir: URL?
    private var savedCount = 0

    // MARK: lifecycle
    /// Panggil dari main thread.
    func start() {
        let mode = rawMode
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { self.setStatus("Izin kamera ditolak"); return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
            self.sessionQueue.async {
                self.configure(mode)
                self.session.startRunning()
                self.setStatus("Siap")
            }
        }
        DispatchQueue.main.async {
            self.readoutTimer?.invalidate()
            self.readoutTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.updateReadout()
            }
        }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
        readoutTimer?.invalidate()
    }

    private func configure(_ mode: RawMode) {
        guard device == nil else { return }   // sudah dikonfigurasi
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: d),
              session.canAddInput(input) else {
            session.commitConfiguration()
            setStatus("Kamera tidak tersedia")
            return
        }
        session.addInput(input)
        device = d

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality

        for conn in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            if let c = conn, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
        session.commitConfiguration()
        applyRawMode(mode)

        let fmt = d.activeFormat
        let minS = max(fmt.minExposureDuration.seconds, 1.0 / 8000)
        let maxS = max(min(fmt.maxExposureDuration.seconds, 1.0), minS * 2)
        let bayer = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let pro = photoOutput.isAppleProRAWSupported
        Log.camera.info("Kamera siap. ISO \(fmt.minISO, privacy: .public)-\(fmt.maxISO, privacy: .public), shutter \(minS, privacy: .public)-\(maxS, privacy: .public)s, Bayer \(bayer, privacy: .public), ProRAW \(pro, privacy: .public)")
        DispatchQueue.main.async {
            self.isoRange = fmt.minISO...fmt.maxISO
            self.shutterRange = minS...maxS
            self.supportsBayer = bayer
            self.supportsProRAW = pro
        }
    }

    /// ProRAW harus di-enable di photo output sebelum dipakai; Bayer RAW butuh ProRAW off.
    func setRawMode(_ mode: RawMode) {
        rawMode = mode
        sessionQueue.async { self.applyRawMode(mode) }
    }

    private func applyRawMode(_ mode: RawMode) {
        let wantPro = mode == .proraw && photoOutput.isAppleProRAWSupported
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
            if d.isWhiteBalanceModeSupported(.locked) {
                let tv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temp, tint: 0)
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

    private func updateReadout() {
        guard let d = device else { return }
        liveISO = d.iso
        liveShutter = d.exposureDuration.seconds
        liveLens = d.lensPosition
        let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
        liveTemp = tt.temperature
    }

    // MARK: burst capture
    func startBurst() {
        guard !isCapturing else { return }
        isCapturing = true
        let count = max(1, burstCount), auto = isAuto, mode = rawMode
        sessionQueue.async {
            self.burstAuto = auto
            self.burstMode = mode
            self.burstRemaining = count
            self.burstIndex = 0
            self.savedCount = 0
            self.burstDir = Self.makeBurstDir()
            if auto { self.lockCurrent() }
            Log.camera.info("Burst mulai: \(count, privacy: .public) frame, mode \(mode.rawValue, privacy: .public)")
            self.setStatus("Burst 0/\(count)")
            // beri waktu kunci AE/AWB/AF stabil
            self.sessionQueue.asyncAfter(deadline: .now() + 0.15) { self.captureNext() }
        }
    }

    private func captureNext() {
        guard burstRemaining > 0 else { finishBurst(); return }
        burstRemaining -= 1
        burstIndex += 1
        photoOutput.capturePhoto(with: makeSettings(burstMode), delegate: self)
    }

    private func finishBurst() {
        if burstAuto { applyAuto() }
        let n = burstIndex, dir = burstDir?.lastPathComponent ?? "-"
        Log.camera.info("Burst selesai: \(n, privacy: .public) frame -> \(dir, privacy: .public)")
        DispatchQueue.main.async {
            self.isCapturing = false
            self.status = "Tersimpan \(n) frame (\(dir))"
        }
    }

    private func makeSettings(_ mode: RawMode) -> AVCapturePhotoSettings {
        let raws = photoOutput.availableRawPhotoPixelFormatTypes
        switch mode {
        case .bayer:
            if let fmt = raws.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
                let s = AVCapturePhotoSettings(rawPixelFormatType: fmt)
                s.photoQualityPrioritization = .speed
                return s
            }
        case .proraw:
            if let fmt = raws.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                let s = AVCapturePhotoSettings(rawPixelFormatType: fmt)
                s.photoQualityPrioritization = .quality
                return s
            }
        case .heif:
            break
        }
        let s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        s.photoQualityPrioritization = .balanced
        return s
    }

    private static func makeBurstDir() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bursts", isDirectory: true)
            .appendingPathComponent(f.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func save(_ data: Data, isRaw: Bool, index: Int) {
        let ext = isRaw ? "dng" : "heic"
        if let dir = burstDir {
            let url = dir.appendingPathComponent(String(format: "IMG_%04d.%@", index, ext))
            do { try data.write(to: url) } catch {
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
        guard let data = photo.fileDataRepresentation() else { return }
        let md = photo.metadata["{Exif}"] as? [String: Any]
        let iso = (md?["ISOSpeedRatings"] as? [Any])?.first.map { "\($0)" } ?? "?"
        let exp = md?["ExposureTime"].map { "\($0)" } ?? "?"
        sessionQueue.async {
            self.savedCount += 1
            let idx = self.savedCount
            self.save(data, isRaw: photo.isRawPhoto, index: idx)
            Log.camera.info("Frame \(idx, privacy: .public): raw=\(photo.isRawPhoto, privacy: .public) \(data.count / 1024, privacy: .public) KB ISO \(iso, privacy: .public) exp \(exp, privacy: .public)")
            self.setStatus("Burst \(idx)/\(self.burstIndex + self.burstRemaining)")
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
