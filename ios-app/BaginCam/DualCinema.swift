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

/// Sesi multi-kamera sendiri. configure/setZoom dari antrean sesi; frame, `swapped`, `pipCenter` di antrean video.
final class DualCam: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    static var supported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }
    /// kotak kecil = 30 % lebar & tinggi frame
    static let pipScale: CGFloat = 0.3

    let session = AVCaptureMultiCamSession()
    private let backOut = AVCaptureVideoDataOutput()
    private let frontOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var backDevice: AVCaptureDevice?
    private(set) var hasAudio = false
    private(set) var outW = 1080, outH = 1920
    /// lensa belakang fisik; nil = kamera virtual (iOS pindah lensa sendiri mengikuti zoom, juga saat merekam)
    private(set) var backLens: CameraManager.Lens?
    /// zoom di layar saat videoZoomFactor = 1
    private(set) var backBase: CGFloat = 1
    private(set) var backName = ""
    /// true = kamera depan jadi gambar utama, belakang jadi kotak kecil
    var swapped = false
    /// pusat kotak kecil, 0..1 dari kiri-atas frame
    var pipCenter = CGPoint(x: 0.817, y: 0.228)
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?

    private var latestFront: CVPixelBuffer?
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var maskRect = CGRect.null
    private var pipMask = CIImage.empty()
    private var pipBorder = CIImage.empty()

    private static func roundedRect(_ r: CGRect, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: r), "inputRadius": radius, "inputColor": CIColor.white,
        ])?.outputImage?.cropped(to: r) ?? CIImage(color: .white).cropped(to: r)
    }

    private static func multiCamOK(_ f: AVCaptureDevice.Format) -> Bool {
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return f.isMultiCamSupported
            && (sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
    }

    private static func pickFormat(_ d: AVCaptureDevice, uhd: Bool) -> AVCaptureDevice.Format? {
        let sizes: [(Int32, Int32)] = uhd ? [(3840, 2160), (1920, 1080), (1280, 720)] : [(1920, 1080), (1280, 720)]
        for (w, h) in sizes {
            if let f = d.formats.first(where: { f in
                let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return multiCamOK(f) && dim.width == w && dim.height == h
            }) { return f }
        }
        return nil
    }

    /// untuk log: ukuran format multi-kamera yang disediakan iOS per kamera
    static func describeFormats() -> String {
        let types: [(String, AVCaptureDevice.DeviceType, AVCaptureDevice.Position)] = [
            ("virtual", .builtInTripleCamera, .back), ("utama", .builtInWideAngleCamera, .back),
            ("uw", .builtInUltraWideCamera, .back), ("tele", .builtInTelephotoCamera, .back),
            ("depan", .builtInWideAngleCamera, .front)]
        return types.map { name, t, pos in
            guard let d = AVCaptureDevice.default(t, for: .video, position: pos) else { return "\(name): -" }
            var seen: [String] = []
            for f in d.formats where multiCamOK(f) {
                let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let k = "\(dim.width)x\(dim.height)"
                if !seen.contains(k) { seen.append(k) }
            }
            return "\(name): \(seen.isEmpty ? "tidak ada" : seen.joined(separator: " "))"
        }.joined(separator: "; ")
    }

    private func addCamera(_ d: AVCaptureDevice, out: AVCaptureVideoDataOutput, mirrored: Bool, uhd: Bool, queue: DispatchQueue) -> Bool {
        guard let fmt = Self.pickFormat(d, uhd: uhd), let input = try? AVCaptureDeviceInput(device: d),
              session.canAddInput(input) else { return false }
        session.addInputWithNoConnections(input)
        if (try? d.lockForConfiguration()) != nil {
            d.activeFormat = fmt
            let dur = CMTime(value: 1, timescale: 30)
            d.activeVideoMinFrameDuration = dur
            d.activeVideoMaxFrameDuration = dur
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

    /// lens nil = kamera virtual belakang. uhd = coba 4K untuk kamera belakang (depan tetap 1080p).
    func configure(queue: DispatchQueue, lens: CameraManager.Lens?, uhd: Bool, zoom: CGFloat) -> Bool {
        guard Self.supported, let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return false }
        let back: AVCaptureDevice
        if let lens {
            guard let d = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else { return false }
            back = d
            backBase = lens == .ultraWide ? 0.5 : (lens == .tele ? CameraManager.teleNative : 1)
        } else {
            guard let d = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) else { return false }
            back = d
            let sw = d.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat($0.doubleValue) } ?? 1
            backBase = d.constituentDevices.first?.deviceType == .builtInUltraWideCamera ? 1 / max(sw, 1) : 1
        }
        backLens = lens
        backName = lens?.displayName ?? "Auto"
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard addCamera(back, out: backOut, mirrored: false, uhd: uhd, queue: queue),
              addCamera(front, out: frontOut, mirrored: true, uhd: false, queue: queue) else { return false }
        backDevice = back
        let dim = CMVideoFormatDescriptionGetDimensions(back.activeFormat.formatDescription)
        outW = Int(dim.height)
        outH = Int(dim.width)
        _ = setZoom(zoom)
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

    /// zoom di layar (1x = lensa utama) -> zoom yang benar-benar terpasang
    func setZoom(_ z: CGFloat) -> CGFloat {
        guard let d = backDevice, (try? d.lockForConfiguration()) != nil else { return z }
        let maxF = min(d.maxAvailableVideoZoomFactor, backLens == nil ? 15 / backBase : 6)
        let f = min(max(z / backBase, d.minAvailableVideoZoomFactor), maxF)
        d.videoZoomFactor = f
        d.unlockForConfiguration()
        return f * backBase
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOut { onAudio?(sampleBuffer); return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if output === frontOut { latestFront = pb; return }
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
                                        kCVPixelBufferWidthKey as String: outW, kCVPixelBufferHeightKey as String: outH,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        guard let dst else { return nil }
        let W = CGFloat(outW), H = CGFloat(outH)
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        var img = fit(main, into: full)
        if let small {
            let w = W * Self.pipScale, h = H * Self.pipScale
            let r = CGRect(x: pipCenter.x * W - w / 2, y: (1 - pipCenter.y) * H - h / 2, width: w, height: h).integral
            if r != maskRect {
                maskRect = r
                let b = (w * 0.015).rounded()
                pipMask = Self.roundedRect(r, radius: w * 0.08)
                pipBorder = Self.roundedRect(r.insetBy(dx: -b, dy: -b), radius: w * 0.08 + b)
            }
            let bg = pipBorder.composited(over: img)
            img = fit(small, into: r).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: pipMask,
            ]).cropped(to: full)
        }
        ctx.render(img, to: dst, bounds: full, colorSpace: nil)
        CVBufferPropagateAttachments(main, dst)
        return dst
    }
}
