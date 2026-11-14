import AVFoundation
import CoreImage
import QuartzCore
import Vision

// MARK: - SINEMA: bokeh latar real-time (segmentasi orang per frame)

/// Dipakai dari antrean video saja.
final class CinematicProcessor {
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let seq = VNSequenceRequestHandler()
    private let req: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var frames = 0, withPerson = 0
    private var totalMs = 0.0

    /// frame dengan latar diblur, atau nil (tidak ada orang / gagal) -> pakai frame asli
    func process(_ pb: CVPixelBuffer, intensity: Double) -> CVPixelBuffer? {
        let t0 = CACurrentMediaTime()
        defer { stats(t0) }
        guard (try? seq.perform([req], on: pb)) != nil, let mask = req.results?.first?.pixelBuffer,
              Self.hasPerson(mask) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let dst = makeBuffer(w, h) else { return nil }
        let src = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
        let ext = src.extent
        let rawMask = CIImage(cvPixelBuffer: mask, options: [.colorSpace: NSNull()])
        let m = rawMask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.5])
            .cropped(to: rawMask.extent)
            .transformed(by: CGAffineTransform(scaleX: ext.width / rawMask.extent.width, y: ext.height / rawMask.extent.height))
        // blur di 1/4 resolusi: jauh lebih ringan, hasil sama untuk latar yang memang buram
        let t = max(0.1, min(1, intensity / 100))
        let radius = Double(min(w, h)) / 45.0 * t
        let bg = src.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius / 4])
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
            .cropped(to: ext)
        let out = src.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: m,
        ]).cropped(to: ext)
        ctx.render(out, to: dst, bounds: ext, colorSpace: nil)
        CVBufferPropagateAttachments(pb, dst)
        withPerson += 1
        return dst
    }

    private func stats(_ t0: CFTimeInterval) {
        totalMs += (CACurrentMediaTime() - t0) * 1000
        frames += 1
        guard frames >= 300 else { return }
        Log.camera.info("SINEMA: \(self.totalMs / Double(self.frames), format: .fixed(precision: 1), privacy: .public) ms/frame, orang terdeteksi \(self.withPerson * 100 / self.frames, privacy: .public)%")
        frames = 0; withPerson = 0; totalMs = 0
    }

    private static func hasPerson(_ mask: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return false }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var hit = 0, n = 0
        for y in stride(from: 0, to: h, by: 12) {
            for x in stride(from: 0, to: w, by: 12) {
                n += 1
                if p[y * row + x] > 128 { hit += 1 }
            }
        }
        return n > 0 && hit * 100 >= n      // >= 1 % frame
    }

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != w || poolH != h {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p; poolW = w; poolH = h
        }
        guard let pool else { return nil }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        return dst
    }
}

// MARK: - DUAL: kamera belakang + depan sekaligus (picture-in-picture)

/// Sesi multi-kamera sendiri. configure/start/stop/setZoom dari antrean sesi; frame & `swapped` di antrean video.
final class DualCam: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    static var supported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }
    static let outW = 1080, outH = 1920

    let session = AVCaptureMultiCamSession()
    private let backOut = AVCaptureVideoDataOutput()
    private let frontOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var backDevice: AVCaptureDevice?
    private(set) var hasAudio = false
    /// true = kamera depan jadi gambar utama, belakang jadi kotak kecil
    var swapped = false
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?

    private var latestBack: CVPixelBuffer?
    private var latestFront: CVPixelBuffer?
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private lazy var pipRect: CGRect = {
        let w = CGFloat(Self.outW) * 0.3, h = CGFloat(Self.outH) * 0.3
        return CGRect(x: CGFloat(Self.outW) - w - 36, y: CGFloat(Self.outH) - h - 150, width: w, height: h)
    }()
    private lazy var pipMask = Self.roundedRect(pipRect, radius: 26)
    private lazy var pipBorder = Self.roundedRect(pipRect.insetBy(dx: -5, dy: -5), radius: 31)

    private static func roundedRect(_ r: CGRect, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: r), "inputRadius": radius, "inputColor": CIColor.white,
        ])?.outputImage?.cropped(to: r) ?? CIImage(color: .white).cropped(to: r)
    }

    private static func pickFormat(_ d: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func ok(_ f: AVCaptureDevice.Format, _ w: Int32, _ h: Int32) -> Bool {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return f.isMultiCamSupported && dim.width == w && dim.height == h
                && (sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        return d.formats.first { ok($0, 1920, 1080) } ?? d.formats.first { ok($0, 1280, 720) }
    }

    private func addCamera(_ d: AVCaptureDevice, out: AVCaptureVideoDataOutput, mirrored: Bool, queue: DispatchQueue) -> Bool {
        guard let fmt = Self.pickFormat(d), let input = try? AVCaptureDeviceInput(device: d),
              session.canAddInput(input) else { return false }
        session.addInputWithNoConnections(input)
        if (try? d.lockForConfiguration()) != nil {
            d.activeFormat = fmt
            let dur = CMTime(value: 1, timescale: 30)
            d.activeVideoMinFrameDuration = dur
            d.activeVideoMaxFrameDuration = dur
            d.videoZoomFactor = 1
            d.unlockForConfiguration()
        }
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { return false }
        session.addOutputWithNoConnections(out)
        guard let port = input.ports(for: .video, sourceDeviceType: d.deviceType, sourceDevicePosition: d.position).first else { return false }
        let conn = AVCaptureConnection(inputPorts: [port], output: out)
        guard session.canAddConnection(conn) else { return false }
        session.addConnection(conn)
        if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = mirrored
        }
        return true
    }

    func configure(queue: DispatchQueue) -> Bool {
        guard Self.supported,
              let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard addCamera(back, out: backOut, mirrored: false, queue: queue),
              addCamera(front, out: frontOut, mirrored: true, queue: queue) else { return false }
        backDevice = back
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio), let inp = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(inp), session.canAddOutput(audioOut) {
            session.addInputWithNoConnections(inp)
            session.addOutputWithNoConnections(audioOut)
            let port = inp.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .back).first
                ?? inp.ports.first { $0.mediaType == .audio }
            if let port {
                let conn = AVCaptureConnection(inputPorts: [port], output: audioOut)
                if session.canAddConnection(conn) {
                    session.addConnection(conn)
                    audioOut.setSampleBufferDelegate(self, queue: queue)
                    hasAudio = true
                }
            }
        }
        return true
    }

    func setZoom(_ z: CGFloat) {
        guard let d = backDevice, (try? d.lockForConfiguration()) != nil else { return }
        d.videoZoomFactor = min(max(z, d.minAvailableVideoZoomFactor), min(d.maxAvailableVideoZoomFactor, 6))
        d.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOut { onAudio?(sampleBuffer); return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if output === frontOut { latestFront = pb; return }
        latestBack = pb
        // kamera belakang jadi jam: satu frame keluaran per frame belakang
        let main = swapped ? (latestFront ?? pb) : pb
        let small = swapped ? pb : latestFront
        guard let out = compose(main: main, small: small) else { return }
        onVideo?(out, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func fit(_ pb: CVPixelBuffer, into r: CGRect) -> CIImage {
        let img = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
        let s = max(r.width / img.extent.width, r.height / img.extent.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = r.midX - scaled.extent.midX, dy = r.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: r)
    }

    private func compose(main: CVPixelBuffer, small: CVPixelBuffer?) -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: Self.outW, kCVPixelBufferHeightKey as String: Self.outH,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        guard let dst else { return nil }
        let full = CGRect(x: 0, y: 0, width: Self.outW, height: Self.outH)
        var img = fit(main, into: full)
        if let small {
            let bg = pipBorder.composited(over: img)
            img = fit(small, into: pipRect).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: pipMask,
            ]).cropped(to: full)
        }
        ctx.render(img, to: dst, bounds: full, colorSpace: nil)
        CVBufferPropagateAttachments(main, dst)
        return dst
    }
}
