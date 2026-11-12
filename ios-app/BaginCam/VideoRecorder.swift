import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import VideoToolbox

// MARK: - pilihan video (ala Blackmagic Camera + GCam)

enum VideoRes: String, CaseIterable, Identifiable {
    case uhd = "4K"
    case fhd = "1080p"
    var id: String { rawValue }
    /// dimensi sensor (lanskap)
    var size: (w: Int32, h: Int32) { self == .uhd ? (3840, 2160) : (1920, 1080) }
}

/// 0 = Auto (60 saat terang, 30 saat gelap - seperti AutoFps GCam taoyao)
enum VideoFps: Int, CaseIterable, Identifiable {
    case auto = 0, f24 = 24, f25 = 25, f30 = 30, f50 = 50, f60 = 60, f120 = 120, f240 = 240
    var id: Int { rawValue }
    var label: String { self == .auto ? "Auto" : "\(rawValue)" }
    var isSlowMo: Bool { rawValue >= 100 }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC (H.265)"
    case h264 = "H.264"
    case proresHQ = "ProRes 422 HQ"
    case prores = "ProRes 422"
    case proresLT = "ProRes 422 LT"
    case proresProxy = "ProRes Proxy"
    var id: String { rawValue }
    var short: String {
        switch self {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .proresHQ: return "ProRes HQ"
        case .prores: return "ProRes"
        case .proresLT: return "ProRes LT"
        case .proresProxy: return "ProRes Proxy"
        }
    }
    var isProRes: Bool { self != .hevc && self != .h264 }
    var avType: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proresHQ: return .proRes422HQ
        case .prores: return .proRes422
        case .proresLT: return .proRes422LT
        case .proresProxy: return .proRes422Proxy
        }
    }
    /// perkiraan bitrate (Mbps) untuk sisa waktu rekam
    func mbps(_ res: VideoRes, fps: Int, tenBit: Bool) -> Double {
        let px = res == .uhd ? 1.0 : 0.25
        let f = Double(max(fps, 24)) / 30
        switch self {
        case .hevc: return (res == .uhd ? 50 : 16) * max(1, f * 0.8) * (tenBit ? 1.2 : 1)
        case .h264: return (res == .uhd ? 80 : 26) * max(1, f * 0.8)
        case .proresHQ: return 707 * px * f
        case .prores: return 471 * px * f
        case .proresLT: return 328 * px * f
        case .proresProxy: return 145 * px * f
        }
    }
}

enum VideoColor: String, CaseIterable, Identifiable {
    case sdr = "Rec.709 (SDR)"
    case hlg = "HDR HLG"
    case log = "Apple Log"
    var id: String { rawValue }
    var short: String { self == .sdr ? "709" : (self == .hlg ? "HLG" : "Log") }
    var tenBit: Bool { self != .sdr }
    var avSpace: AVCaptureColorSpace { self == .sdr ? .sRGB : (self == .hlg ? .HLG_BT2020 : .appleLog) }
}

enum VideoStab: String, CaseIterable, Identifiable {
    case off = "Mati"
    case standard = "Standard"
    case cinematic = "Cinematic"
    case cinematicExtended = "Cinematic Extended"
    var id: String { rawValue }
    var av: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .cinematicExtended: return .cinematicExtended
        }
    }
}

enum VideoSaveTo: String, CaseIterable, Identifiable {
    case photos = "Foto"
    case files = "Files (app)"
    case both = "Foto + Files"
    var id: String { rawValue }
}

/// panduan bingkai (frame guide) seperti Blackmagic
enum FrameGuide: String, CaseIterable, Identifiable {
    case off = "Mati"
    case r239 = "2.39:1"
    case r185 = "1.85:1"
    case r169 = "16:9"
    case r43 = "4:3"
    case r11 = "1:1"
    case r916 = "9:16"
    var id: String { rawValue }
    /// lebar / tinggi saat HP lanskap
    var ratio: CGFloat? {
        switch self {
        case .off: return nil
        case .r239: return 2.39
        case .r185: return 1.85
        case .r169: return 16.0 / 9.0
        case .r43: return 4.0 / 3.0
        case .r11: return 1
        case .r916: return 9.0 / 16.0
        }
    }
}

// MARK: - Apple Log -> Rec.709 (untuk preview & LUT dibakar)

enum AppleLogLUT {
    /// kurva Apple Log (Apple Log Profile white paper): kode 0..1 -> linear (refleksi relatif)
    static func toLinear(_ l: Double) -> Double {
        let r0 = -0.05641088, c = 47.28711236, b = 0.00964052, g = 0.08550479, beta = 0.69336945
        let lt = c * pow(0.01 - r0, 2)
        if l < 0 { return r0 }
        if l < lt { return (l / c).squareRoot() + r0 }
        return pow(2, (l - beta) / g) - b
    }

    /// cube 33^3: Log (Rec.2020) -> tone map lembut -> Rec.709, keluaran ter-encode sRGB
    static func makeFilter() -> CIFilter {
        let n = 33
        var data = [Float](repeating: 0, count: n * n * n * 4)
        let m: [[Double]] = [[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]]
        func tone(_ x: Double) -> Double {
            let y = max(0, x) * 1.25
            return min(1, y * (1 + y / 16) / (1 + y))
        }
        func srgb(_ y: Double) -> Double { y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055 }
        var i = 0
        for bz in 0..<n {
            for gy in 0..<n {
                for rx in 0..<n {
                    let lin = [rx, gy, bz].map { toLinear(Double($0) / Double(n - 1)) }
                    for ch in 0..<3 {
                        let v = m[ch][0] * lin[0] + m[ch][1] * lin[1] + m[ch][2] * lin[2]
                        data[i + ch] = Float(srgb(tone(v)))
                    }
                    data[i + 3] = 1
                    i += 4
                }
            }
        }
        let f = CIFilter.colorCube()
        f.cubeDimension = Float(n)
        f.cubeData = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return f
    }
}

// MARK: - perekam (AVAssetWriter), dipakai di antrean video

struct VideoConfig {
    var url: URL
    var width: Int            // dimensi buffer (sudah diputar ke potret)
    var height: Int
    var sensorFps: Int
    var playbackFps: Int      // slow-mo: 24/30; normal = sensorFps
    var timelapse: Int        // 1 = normal, k = ambil 1 dari k frame, diputar 30 fps
    var codec: VideoCodec
    var color: VideoColor
    var audio: Bool
    var transform: CGAffineTransform
    var bake: CubeLUT?        // LUT dibakar (keluaran Rec.709)
    var bakeLog: Bool         // sumber Apple Log -> konversi ke Rec.709 dulu
}

final class VideoRecorder {
    let config: VideoConfig
    private let writer: AVAssetWriter
    private let vIn: AVAssetWriterInput
    private let aIn: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    private var startPTS = CMTime.zero
    private var frameIndex = 0
    private var written = 0
    private var stopping = false
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private lazy var lutFilter: CIFilter? = config.bake?.makeFilter()
    private lazy var logFilter = AppleLogLUT.makeFilter()
    private(set) var droppedFrames = 0

    init(_ c: VideoConfig) throws {
        config = c
        writer = try AVAssetWriter(outputURL: c.url, fileType: .mov)
        var vs: [String: Any] = [AVVideoCodecKey: c.codec.avType, AVVideoWidthKey: c.width, AVVideoHeightKey: c.height]
        if !c.codec.isProRes {
            let fps = c.timelapse > 1 ? 30 : c.playbackFps
            var comp: [String: Any] = [
                AVVideoAverageBitRateKey: Int(c.codec.mbps(c.width * c.height > 4_000_000 ? .uhd : .fhd,
                                                            fps: c.sensorFps, tenBit: c.color.tenBit && c.bake == nil) * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
            ]
            if c.codec == .hevc {
                comp[AVVideoProfileLevelKey] = (c.color.tenBit && c.bake == nil)
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : kVTProfileLevel_HEVC_Main_AutoLevel as String
            } else {
                comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            vs[AVVideoCompressionPropertiesKey] = comp
        }
        // warna: dibakar / SDR = Rec.709, HLG = BT.2020 HLG; Apple Log = ikut atribut buffer kamera
        if c.bake != nil || c.color == .sdr {
            vs[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                             AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                             AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        } else if c.color == .hlg {
            vs[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                             AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                                             AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        vIn.expectsMediaDataInRealTime = true
        vIn.transform = c.transform
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey as String: c.width,
                                    kCVPixelBufferHeightKey as String: c.height,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(vIn) else { throw NSError(domain: "BaginCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "codec tidak didukung"]) }
        writer.add(vIn)
        if c.audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 160_000])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) { writer.add(a); aIn = a } else { aIn = nil }
        } else {
            aIn = nil
        }
    }

    var seconds: Double {
        guard started else { return 0 }
        let fps = Double(config.timelapse > 1 ? 30 : config.playbackFps)
        return Double(written) / max(fps, 1)
    }

    /// antrean video
    func appendVideo(_ pb: CVPixelBuffer, pts: CMTime) {
        guard !stopping else { return }
        if !started {
            guard writer.startWriting() else {
                Log.camera.error("Video: startWriting gagal \(String(describing: self.writer.error), privacy: .public)")
                stopping = true
                return
            }
            writer.startSession(atSourceTime: pts)
            startPTS = pts
            started = true
        }
        frameIndex += 1
        if config.timelapse > 1 && (frameIndex - 1) % config.timelapse != 0 { return }
        // waktu keluaran: slow-mo diregangkan (sensor/putar), time-lapse = n/30
        let out: CMTime
        if config.timelapse > 1 {
            out = CMTimeAdd(startPTS, CMTime(value: CMTimeValue(written), timescale: 30))
        } else if config.playbackFps != config.sensorFps {
            let k = Double(config.sensorFps) / Double(config.playbackFps)
            out = CMTimeAdd(startPTS, CMTimeMultiplyByFloat64(CMTimeSubtract(pts, startPTS), multiplier: k))
        } else {
            out = pts
        }
        guard vIn.isReadyForMoreMediaData else { droppedFrames += 1; return }
        var buffer = pb
        if config.bake != nil || config.bakeLog, let pool = adaptor.pixelBufferPool {
            var dst: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
            if let dst {
                var img = config.bakeLog ? CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
                                         : CIImage(cvPixelBuffer: pb)
                if config.bakeLog {
                    logFilter.setValue(img, forKey: kCIInputImageKey)
                    img = (logFilter.outputImage ?? img).matchedToWorkingSpace(from: CGColorSpace(name: CGColorSpace.sRGB)!) ?? img
                }
                if let f = lutFilter {
                    f.setValue(img, forKey: kCIInputImageKey)
                    img = f.outputImage ?? img
                }
                ciContext.render(img, to: dst, bounds: CGRect(x: 0, y: 0, width: config.width, height: config.height),
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                buffer = dst
            }
        }
        if adaptor.append(buffer, withPresentationTime: out) { written += 1 } else { droppedFrames += 1 }
    }

    /// antrean video (output audio memakai antrean yang sama)
    func appendAudio(_ sb: CMSampleBuffer) {
        guard started, !stopping, let aIn, aIn.isReadyForMoreMediaData,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), startPTS) >= 0 else { return }
        aIn.append(sb)
    }

    /// antrean video
    func stop(_ done: @escaping (URL?, Error?) -> Void) {
        stopping = true
        guard started else {
            writer.cancelWriting()
            done(nil, NSError(domain: "BaginCam", code: 2, userInfo: [NSLocalizedDescriptionKey: "tidak ada frame"]))
            return
        }
        vIn.markAsFinished()
        aIn?.markAsFinished()
        let url = config.url
        writer.finishWriting { [writer] in
            done(writer.status == .completed ? url : nil, writer.error)
        }
    }
}
