import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - AI Upscale video setelah rekam (v0.12, eksperimen)
// Tiap frame: Real-ESRGAN (model AI Zoom yang sama) -> campur dengan Lanczos (kekuatan) ->
// "kurangi kedip": detail AI dirata-rata dengan frame sebelumnya di area yang diam.
// Audio disalin apa adanya. Video HDR (HLG) dikonversi ke Rec.709; Apple Log ditolak (bakar LUT dulu).

enum UpscaleMode: String, CaseIterable, Identifiable {
    case enlarge = "Perbesar 2x (maks 4K)"
    case enhance = "Pertajam (resolusi sama)"
    var id: String { rawValue }
}

struct UpscaleOptions: Equatable {
    var model: SRModel = .fast
    var mode: UpscaleMode = .enlarge
    var strength: Double = 0.8
    var stabilize = true
    var saveTo: VideoSaveTo = .photos

    /// v0.12.2: pilihan diingat (dulu direset tiap layar dibuka)
    static func load(model: SRModel, saveTo: VideoSaveTo) -> UpscaleOptions {
        var o = UpscaleOptions()
        o.model = Prefs.raw("upModel", model)
        o.mode = Prefs.raw("upMode", UpscaleMode.enlarge)
        o.strength = min(max(Prefs.get("upStrength", 0.8), 0.3), 1)
        o.stabilize = Prefs.get("upStabilize", true)
        o.saveTo = Prefs.raw("upSaveTo", saveTo)
        return o
    }

    func store() {
        Prefs.set("upModel", model.rawValue)
        Prefs.set("upMode", mode.rawValue)
        Prefs.set("upStrength", strength)
        Prefs.set("upStabilize", stabilize)
        Prefs.set("upSaveTo", saveTo.rawValue)
    }
}

struct UpscaleInfo {
    var width = 0, height = 0, outWidth = 0, outHeight = 0
    var frames = 0
    var fps: Double = 30
    var seconds: Double = 0
    var tilesPerFrame = 0
    var estimate: Double = 0      // detik
    var note = ""
}

enum UpscaleError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
}

final class VideoUpscaler {
    private var cancelled = false
    private var paused = false                  // v0.12.3: jeda -> potongan disimpan, bisa dilanjutkan
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func cancel() { cancelled = true }
    func pause() { paused = true }

    static func perTile(_ m: SRModel) -> Double { m == .fast ? 0.035 : 0.22 }

    static func outScale(w: Int, h: Int, mode: UpscaleMode) -> Double {
        guard mode == .enlarge else { return 1 }
        let k = min(2, 3840 / Double(max(w, h)), 2160 / Double(min(w, h)))
        return k < 1.15 ? 1 : k
    }

    static func even(_ v: Double) -> Int { max(2, Int(v.rounded()) / 2 * 2) }

    /// info + perkiraan waktu sebelum mulai
    static func inspect(_ url: URL, _ o: UpscaleOptions) async throws -> UpscaleInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw UpscaleError.msg("Tidak ada trek video") }
        let (size, tf, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let dur = try await asset.load(.duration).seconds
        let r = CGRect(origin: .zero, size: size).applying(tf)
        let w = Int(abs(r.width).rounded()), h = Int(abs(r.height).rounded())
        var info = UpscaleInfo()
        info.width = w; info.height = h
        info.fps = Double(rate > 0 ? rate : 30)
        info.seconds = dur
        info.frames = max(1, Int((dur * info.fps).rounded()))
        let k = outScale(w: w, h: h, mode: o.mode)
        info.outWidth = even(Double(w) * k); info.outHeight = even(Double(h) * k)
        let core = Double(SRUpscaler.tile - 2 * SRUpscaler.pad)
        info.tilesPerFrame = Int(ceil(Double(w) / core) * ceil(Double(h) / core))
        info.estimate = Double(info.frames) * (Double(info.tilesPerFrame) * perTile(o.model) + 0.08)
        if o.mode == .enlarge && k == 1 { info.note = "Video sudah ~4K: diproses sebagai Pertajam (resolusi sama)." }
        if try await isLog(track) { info.note = "Video Apple Log tidak didukung - rekam dengan LUT dibakar atau Rec.709." }
        return info
    }

    private static func isLog(_ track: AVAssetTrack) async throws -> Bool {
        for fd in try await track.load(.formatDescriptions) {
            if let t = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
               t.lowercased().contains("log") { return true }
        }
        return false
    }

    /// progress(selesai, total, detik per frame). Kembali (job, URL hasil) — URL nil = dijeda (lanjutkan nanti).
    /// v0.12.3: video ditulis per potongan di Documents/AIJob; dijeda bila app ditinggal, digabung + audio di akhir.
    func run(_ job0: AIJob, progress: @escaping (Int, Int, Double) -> Void) async throws -> (AIJob, URL?) {
        var job = job0
        let o = job.options
        let url = job.inputURL
        let asset = AVURLAsset(url: url)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw UpscaleError.msg("Tidak ada trek video") }
        if try await Self.isLog(vTrack) { throw UpscaleError.msg("Apple Log belum didukung") }
        let info = try await Self.inspect(url, o)
        guard let sr = SRUpscaler(model: o.model) else { throw UpscaleError.msg("Model AI \(o.model.rawValue) tidak ada") }
        let frameDur = 1 / max(info.fps, 1)

        // komposisi: putar sesuai orientasi + HDR -> Rec.709
        let comp = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let w = Int(comp.renderSize.width), h = Int(comp.renderSize.height)
        let k = Self.outScale(w: w, h: h, mode: o.mode)
        let ow = Self.even(Double(w) * k), oh = Self.even(Double(h) * k)

        let reader = try AVAssetReader(asset: asset)
        if job.nextTime > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: job.nextTime, preferredTimescale: 600), duration: .positiveInfinity)
        }
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = comp
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw UpscaleError.msg("Video tidak bisa dibaca") }
        reader.add(vOut)

        try? FileManager.default.createDirectory(at: AIJob.dir, withIntermediateDirectories: true)
        let segName = "seg\(job.segments.count)_\(Int(Date().timeIntervalSince1970)).mov"
        let segURL = AIJob.dir.appendingPathComponent(segName)
        try? FileManager.default.removeItem(at: segURL)
        let writer = try AVAssetWriter(outputURL: segURL, fileType: .mov)
        let mbps = Double(ow * oh) / (3840.0 * 2160.0) * 60 + 8
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: ow, AVVideoHeightKey: oh,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(mbps * 1_000_000),
                                              AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(vIn) else { throw UpscaleError.msg("HEVC tidak tersedia") }
        writer.add(vIn)

        guard reader.startReading() else { throw UpscaleError.msg("Baca gagal: \(reader.error?.localizedDescription ?? "-")") }
        guard writer.startWriting() else { throw UpscaleError.msg("Tulis gagal: \(writer.error?.localizedDescription ?? "-")") }
        Log.sr.info("AI video: \(url.lastPathComponent, privacy: .public) \(w, privacy: .public)x\(h, privacy: .public) -> \(ow, privacy: .public)x\(oh, privacy: .public), \(info.frames, privacy: .public) frame, mulai frame \(job.done, privacy: .public) (\(job.nextTime, format: .fixed(precision: 2), privacy: .public) s), model \(o.model.rawValue, privacy: .public), kedip \(o.stabilize, privacy: .public)")

        var prevBase: CIImage?, prevSR: CIImage?
        var prevCG: CGImage?, prevSRCG: CGImage?
        var segFrames = 0
        var firstPts: CMTime?
        var lastPts = CMTime.zero
        var ended = false
        let t0 = CFAbsoluteTimeGetCurrent()
        var failure: String?
        let startDone = job.done, skipBefore = job.nextTime - frameDur * 0.25
        while !cancelled && !paused {
            let ok: Bool = autoreleasepool {
                guard let sb = vOut.copyNextSampleBuffer() else { ended = true; return false }
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { return true }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if pts.seconds < skipBefore { return true }                 // sudah dikerjakan sebelumnya
                let src = CIImage(cvPixelBuffer: pb)
                guard let cg = ci.createCGImage(src, from: src.extent, format: .BGRA8, colorSpace: srgb),
                      let up = sr.upscale(cg, crop: CGRect(x: 0, y: 0, width: cg.width, height: cg.height), outScale: k) else {
                    failure = "AI gagal di frame \(startDone + segFrames + 1): \(sr.lastError ?? "-")"
                    return false
                }
                let cur = CIImage(cgImage: cg), curSR = CIImage(cgImage: up)
                let curBase = lanczos(cur, to: CGSize(width: ow, height: oh))
                let srImg = curSR.transformed(by: CGAffineTransform(scaleX: CGFloat(ow) / curSR.extent.width,
                                                                    y: CGFloat(oh) / curSR.extent.height))
                // detail AI = SR - Lanczos
                var detail = subtract(srImg, curBase)
                if o.stabilize, let pb0 = prevBase, let ps = prevSR {
                    let prevDetail = subtract(ps, pb0)
                    let still = average(detail, prevDetail)
                    let moving = motionMask(curBase, pb0)        // 1 = bergerak -> pakai detail frame ini saja
                    let b = CIFilter.blendWithMask()
                    b.inputImage = detail
                    b.backgroundImage = still
                    b.maskImage = moving
                    detail = b.outputImage ?? detail
                }
                let out = add(curBase, alphaZero(scale(detail, o.strength))).cropped(to: CGRect(x: 0, y: 0, width: ow, height: oh))
                prevBase = curBase; prevSR = srImg
                prevCG = cg; prevSRCG = up                         // simpan CGImage agar CIImage sebelumnya tetap valid

                while !vIn.isReadyForMoreMediaData && !cancelled && !paused { usleep(3000) }
                // dijeda (app ditinggal): frame ini dibuang, GPU tidak boleh dipakai di latar belakang
                guard !cancelled, !paused, let pool = adaptor.pixelBufferPool else { return false }
                var dst: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
                guard let dst else { failure = "buffer penuh"; return false }
                ci.render(out, to: dst, bounds: CGRect(x: 0, y: 0, width: ow, height: oh), colorSpace: srgb)
                if firstPts == nil { firstPts = pts; writer.startSession(atSourceTime: pts) }
                if !adaptor.append(dst, withPresentationTime: pts) {
                    failure = "tulis frame gagal: \(writer.error?.localizedDescription ?? "-")"
                    return false
                }
                lastPts = pts
                segFrames += 1
                let per = (CFAbsoluteTimeGetCurrent() - t0) / Double(segFrames)
                progress(startDone + segFrames, max(info.frames, startDone + segFrames), per)
                return true
            }
            if !ok { break }
        }
        _ = prevCG; _ = prevSRCG
        reader.cancelReading()

        if cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: segURL)
            throw UpscaleError.msg("Dibatalkan")
        }
        // simpan potongan yang sudah jadi (juga saat dijeda / gagal) -> bisa dilanjutkan
        if let fp = firstPts, segFrames > 0 {
            vIn.markAsFinished()
            writer.endSession(atSourceTime: lastPts + CMTime(seconds: frameDur, preferredTimescale: 6000))
            await writer.finishWriting()
            if writer.status == .completed {
                job.segments.append(.init(file: segName, start: fp.seconds))
                job.done += segFrames
                job.nextTime = lastPts.seconds + frameDur * 0.5
            } else {
                try? FileManager.default.removeItem(at: segURL)
                failure = failure ?? "Simpan potongan gagal: \(writer.error?.localizedDescription ?? "-")"
            }
        } else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: segURL)
        }
        job.save()
        let secs = CFAbsoluteTimeGetCurrent() - t0
        let state = ended ? "habis" : (paused ? "dijeda" : "berhenti")
        Log.sr.info("AI video: potongan \(segFrames, privacy: .public) frame \(secs, format: .fixed(precision: 1), privacy: .public) s, total \(job.done, privacy: .public)/\(info.frames, privacy: .public), \(state, privacy: .public)")
        if let failure { throw UpscaleError.msg(failure + " - bisa dilanjutkan") }
        guard ended else { return (job, nil) }

        // gabung potongan + audio asli
        let base = url.deletingPathExtension().lastPathComponent
        let dir = AIJob.docs.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = k > 1 ? String(format: "AI%.1fx", k) : "AIsharp"
        let outURL = dir.appendingPathComponent("\(base)_\(tag)_\(o.model == .fast ? "C" : "D").mov")
        try? FileManager.default.removeItem(at: outURL)
        try await Self.merge(job, audioFrom: asset, to: outURL)
        Log.sr.info("AI video selesai: \(outURL.lastPathComponent, privacy: .public), \(job.done, privacy: .public) frame, \(job.segments.count, privacy: .public) potongan")
        return (job, outURL)
    }

    private static func merge(_ job: AIJob, audioFrom asset: AVURLAsset, to out: URL) async throws {
        let comp = AVMutableComposition()
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw UpscaleError.msg("Gabung gagal")
        }
        for s in job.segments {
            let a = AVURLAsset(url: AIJob.dir.appendingPathComponent(s.file))
            guard let t = try await a.loadTracks(withMediaType: .video).first else { continue }
            let r = try await t.load(.timeRange)
            try vt.insertTimeRange(r, of: t, at: vt.timeRange.end)
        }
        let vDur = vt.timeRange.duration
        guard vDur.seconds > 0 else { throw UpscaleError.msg("Tidak ada frame hasil") }
        if let at = try await asset.loadTracks(withMediaType: .audio).first,
           let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let r = try await at.load(.timeRange)
            try? ct.insertTimeRange(CMTimeRange(start: r.start, duration: CMTimeMinimum(r.duration, vDur)), of: at, at: .zero)
        }
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw UpscaleError.msg("Ekspor tidak tersedia")
        }
        ex.outputURL = out
        ex.outputFileType = .mov
        await ex.export()
        guard ex.status == .completed else {
            throw UpscaleError.msg("Gabung gagal: \(ex.error?.localizedDescription ?? "-") - potongan tetap tersimpan")
        }
    }

    // MARK: operasi Core Image (ruang kerja float, nilai negatif aman)
    private func lanczos(_ img: CIImage, to size: CGSize) -> CIImage {
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = img
        f.scale = Float(size.height / img.extent.height)
        f.aspectRatio = Float((size.width / img.extent.width) / (size.height / img.extent.height))
        return (f.outputImage ?? img).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func scale(_ img: CIImage, _ k: Double) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = img
        let v = CGFloat(k)
        m.rVector = CIVector(x: v, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: v, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: v, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? img
    }

    private func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.additionCompositing()
        f.inputImage = b
        f.backgroundImage = a
        return f.outputImage ?? a
    }

    private func subtract(_ a: CIImage, _ b: CIImage) -> CIImage {
        // alpha -b = 0 supaya hasil tetap berlapis alpha 1 dari a
        let m = CIFilter.colorMatrix()
        m.inputImage = b
        m.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return add(a, m.outputImage ?? b)
    }

    private func average(_ a: CIImage, _ b: CIImage) -> CIImage {
        add(scale(a, 0.5), alphaZero(scale(b, 0.5)))
    }

    private func alphaZero(_ img: CIImage) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = img
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return m.outputImage ?? img
    }

    /// selisih luminans antar frame (diblur, dikuatkan) -> 0 diam .. 1 bergerak
    private func motionMask(_ a: CIImage, _ b: CIImage) -> CIImage {
        let d = CIFilter.differenceBlendMode()
        d.inputImage = a
        d.backgroundImage = b
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = d.outputImage?.clampedToExtent()
        blur.radius = 6
        let m = CIFilter.colorMatrix()
        m.inputImage = blur.outputImage?.cropped(to: a.extent)
        let g: CGFloat = 12          // selisih ~8 % -> dianggap bergerak penuh
        m.rVector = CIVector(x: 0.3 * g, y: 0.59 * g, z: 0.11 * g, w: 0)
        m.gVector = CIVector(x: 0.3 * g, y: 0.59 * g, z: 0.11 * g, w: 0)
        m.bVector = CIVector(x: 0.3 * g, y: 0.59 * g, z: 0.11 * g, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let c = CIFilter.colorClamp()
        c.inputImage = m.outputImage
        c.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        c.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return c.outputImage ?? a
    }

    /// simpan ke Foto / Files
    static func save(_ url: URL, to: VideoSaveTo) async -> String {
        guard to != .files else { return "Tersimpan di Files: \(url.lastPathComponent)" }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                let opt = PHAssetResourceCreationOptions()
                opt.shouldMoveFile = to == .photos
                req.addResource(with: .video, fileURL: url, options: opt)
            }
            return "Tersimpan di Foto" + (to == .both ? " + Files" : "")
        } catch {
            return "Gagal simpan ke Foto (\(error.localizedDescription)), file tetap di Files"
        }
    }
}

// MARK: - pekerjaan AI (bisa dijeda / dilanjutkan, v0.12.3)

struct AIJob: Codable {
    struct Seg: Codable { var file: String; var start: Double }
    var input: String              // relatif ke Documents
    var deleteInput: Bool          // hapus video sumber setelah selesai (salinan "AI setelah rekam")
    var model: String, mode: String, strength: Double, stabilize: Bool, saveTo: String
    var frames: Int
    var done = 0
    var nextTime: Double = 0       // detik (waktu frame berikutnya)
    var segments: [Seg] = []

    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var dir: URL { docs.appendingPathComponent("AIJob", isDirectory: true) }
    static var file: URL { dir.appendingPathComponent("job.json") }
    var inputURL: URL { Self.docs.appendingPathComponent(input) }
    var inputName: String { (input as NSString).lastPathComponent }

    var options: UpscaleOptions {
        var o = UpscaleOptions()
        o.model = SRModel(rawValue: model) ?? .fast
        o.mode = UpscaleMode(rawValue: mode) ?? .enlarge
        o.strength = strength
        o.stabilize = stabilize
        o.saveTo = VideoSaveTo(rawValue: saveTo) ?? .photos
        return o
    }

    /// pekerjaan baru: video dari galeri (tmp) dipindah ke folder AIJob agar tidak hilang
    static func create(input u: URL, options o: UpscaleOptions, frames: Int, deleteInput: Bool) throws -> AIJob {
        clear()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let docsPath = docs.resolvingSymlinksInPath().path + "/"
        var p = u.resolvingSymlinksInPath().path
        var del = deleteInput
        if !p.hasPrefix(docsPath) {
            let dst = dir.appendingPathComponent(u.lastPathComponent)
            try FileManager.default.moveItem(at: u, to: dst)
            p = dst.resolvingSymlinksInPath().path
            del = false                                   // ikut terhapus bersama folder AIJob
        }
        let rel = String(p.dropFirst(docsPath.count))
        let j = AIJob(input: rel, deleteInput: del, model: o.model.rawValue, mode: o.mode.rawValue,
                      strength: o.strength, stabilize: o.stabilize, saveTo: o.saveTo.rawValue, frames: frames)
        j.save()
        return j
    }

    static func load() -> AIJob? {
        guard let d = try? Data(contentsOf: file), let j = try? JSONDecoder().decode(AIJob.self, from: d),
              FileManager.default.fileExists(atPath: j.inputURL.path) else { return nil }
        return j
    }

    func save() { try? JSONEncoder().encode(self).write(to: Self.file, options: .atomic) }

    /// selesai / dibuang: hapus potongan (+ sumber bila salinan)
    func finish() {
        if deleteInput { try? FileManager.default.removeItem(at: inputURL) }
        Self.clear()
    }

    static func clear() { try? FileManager.default.removeItem(at: dir) }
}

// MARK: - pilih video dari galeri

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai_in", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return Self(url: dst)
        }
    }
}

// MARK: - layar AI Upscale

struct VideoUpscaleView: View {
    @ObservedObject var cam: CameraManager
    /// video baru direkam ("AI setelah rekam"); bila disimpan ke Foto, salinan ini dihapus saat layar ditutup
    var initial: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @State private var input: URL?
    @State private var info: UpscaleInfo?
    @State private var opt = UpscaleOptions()
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var perFrame: Double = 0
    @State private var message = ""
    @State private var upscaler: VideoUpscaler?
    @State private var loading = false
    @State private var job: AIJob?                  // pekerjaan tertunda (v0.12.3)
    @State private var autoResume = false           // dijeda karena app ditinggal -> lanjut sendiri saat kembali
    @State private var bgTask: UIBackgroundTaskIdentifier = .invalid
    @State private var tick = 0

    private var appVideos: [URL] {
        _ = tick
        let dir = AIJob.docs.appendingPathComponent("Videos")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let j = job {
                    Section {
                        Text(j.inputName).font(.caption).foregroundStyle(.secondary)
                        if running {
                            Text("Sedang diproses...").font(.caption)
                        } else {
                            row("Selesai", "\(j.done)/\(j.frames) frame (\(j.frames > 0 ? j.done * 100 / j.frames : 0) %)")
                            Button { start(j) } label: { Label("Lanjutkan", systemImage: "play.fill") }
                            Button("Buang pekerjaan ini", role: .destructive) { j.finish(); job = nil; tick += 1 }
                        }
                    } header: { Text("Belum selesai") } footer: {
                        Text("Proses dijeda bila app ditinggal / layar dikunci. Hasil yang sudah jadi tersimpan, lanjutkan kapan saja.")
                    }
                }

                Section {
                    PhotosPicker(selection: $pick, matching: .videos) {
                        Label("Pilih video dari galeri", systemImage: "photo.on.rectangle")
                    }
                    .disabled(running)
                    if !appVideos.isEmpty {
                        Menu {
                            ForEach(appVideos, id: \.self) { u in
                                Button(u.lastPathComponent) { choose(u) }
                            }
                        } label: { Label("Video di Files (app)", systemImage: "folder") }
                        .disabled(running)
                    }
                    if loading { ProgressView("Menyalin video...") }
                    if let input { Text(input.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                } header: { Text("Video") }

                Section {
                    Picker("Cara", selection: $opt.mode) {
                        ForEach(UpscaleMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Model AI", selection: $opt.model) {
                        ForEach(SRModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Kekuatan AI")
                            Spacer()
                            Text("\(Int(opt.strength * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $opt.strength, in: 0.3...1)
                    }
                    Toggle("Kurangi kedip (rata-rata detail antar frame)", isOn: $opt.stabilize)
                    Picker("Simpan ke", selection: $opt.saveTo) {
                        ForEach(VideoSaveTo.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: { Text("Pengaturan") } footer: {
                    Text("Cepat = model ringan (~0,035 s/tile). Detail = lebih tajam tapi ~6x lebih lama. Kurangi kedip mencegah tekstur 'berdenyut', tapi pada gerakan cepat detail bisa sedikit lebih lembut. Video 1080p ~1,4 s/frame (30 detik video = ~20 menit).")
                }
                .disabled(running)
                .onChange(of: opt.mode) { _, _ in refreshInfo() }
                .onChange(of: opt.model) { _, _ in refreshInfo() }

                if let info {
                    Section {
                        row("Masuk", "\(info.width)x\(info.height) · \(String(format: "%.0f", info.fps)) fps · \(String(format: "%.1f", info.seconds)) s")
                        row("Keluar", "\(info.outWidth)x\(info.outHeight) HEVC")
                        row("Perkiraan", duration(info.estimate) + " (\(info.frames) frame, \(info.tilesPerFrame) tile/frame)")
                        if !info.note.isEmpty { Text(info.note).font(.caption).foregroundStyle(.orange) }
                    } header: { Text("Info") }
                }

                Section {
                    if running {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("\(done)/\(total) frame · \(String(format: "%.2f", perFrame)) s/frame · sisa \(duration(Double(max(total - done, 0)) * perFrame))")
                            .font(.caption.monospacedDigit())
                        Text("Biarkan app terbuka (layar tetap menyala). Bila ditinggal, proses dijeda dan bisa dilanjutkan.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Jeda", role: .destructive) { autoResume = false; upscaler?.pause() }
                    } else {
                        Button { startNew() } label: {
                            Label(job == nil ? "Mulai AI Upscale" : "Mulai baru (yang tertunda dibuang)", systemImage: "sparkles")
                        }
                        .disabled(input == nil || (info?.note.contains("tidak didukung") ?? true))
                    }
                    if !message.isEmpty { Text(message).font(.caption) }
                }
            }
            .navigationTitle("AI Upscale video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tutup") { dismiss() }.disabled(running)
                }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                loading = true
                Task {
                    let m = try? await item.loadTransferable(type: PickedMovie.self)
                    await MainActor.run {
                        loading = false
                        if let m { choose(m.url) } else { message = "Video tidak bisa diambil dari galeri" }
                    }
                }
            }
        }
        .interactiveDismissDisabled(running)
        .onChange(of: opt) { _, o in o.store() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            guard running else { return }
            // app ditinggal / layar dikunci: jeda, simpan potongan (waktu tambahan dari iOS)
            autoResume = true
            if bgTask == .invalid {
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "AI Upscale") { endBg() }
            }
            upscaler?.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if autoResume, !running, let j = job {
                autoResume = false
                start(j)
            }
        }
        .onAppear {
            opt = UpscaleOptions.load(model: cam.srModel, saveTo: cam.videoSaveTo)
            cam.stop()                      // kamera berhenti: GPU / Neural Engine untuk AI
            job = AIJob.load()
            if job == nil { AIJob.clear() }
            if let initial { choose(initial) }
            cleanBroken()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if let initial, cam.videoSaveTo == .photos,
               AIJob.load()?.inputURL.resolvingSymlinksInPath().path != initial.resolvingSymlinksInPath().path {
                try? FileManager.default.removeItem(at: initial)
            }
            cam.start()
        }
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
    }

    private func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d j %02d m", t / 3600, (t % 3600) / 60)
            : (t >= 60 ? String(format: "%d m %02d s", t / 60, t % 60) : "\(t) s")
    }

    private func choose(_ u: URL) {
        input = u
        message = ""
        refreshInfo()
    }

    private func refreshInfo() {
        guard let u = input else { return }
        let o = opt
        Task {
            let i = try? await VideoUpscaler.inspect(u, o)
            await MainActor.run { info = i; if i == nil { message = "Video tidak bisa dibaca" } }
        }
    }

    /// hasil AI lama yang terputus (versi <= 0.12.2 menulis langsung ke Videos) tidak bisa diputar -> hapus
    private func cleanBroken() {
        let list = appVideos.filter { $0.lastPathComponent.contains("_AI") }
        guard !list.isEmpty else { return }
        Task {
            var n = 0
            for u in list {
                let ok = (try? await AVURLAsset(url: u).load(.isPlayable)) ?? false
                if !ok { try? FileManager.default.removeItem(at: u); n += 1 }
            }
            if n > 0 { await MainActor.run { tick += 1; message = "\(n) hasil AI rusak (proses terputus) dihapus" } }
        }
    }

    private func endBg() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    private func startNew() {
        guard let u = input else { return }
        do {
            let del = initial.map { $0.resolvingSymlinksInPath().path == u.resolvingSymlinksInPath().path } == true
                && cam.videoSaveTo == .photos
            let j = try AIJob.create(input: u, options: opt, frames: info?.frames ?? 0, deleteInput: del)
            job = j
            input = nil; info = nil
            start(j)
        } catch {
            message = "Gagal menyiapkan: \(error.localizedDescription)"
        }
    }

    private func start(_ j: AIJob) {
        let up = VideoUpscaler()
        upscaler = up
        running = true
        done = j.done; total = j.frames; perFrame = 0
        message = ""
        UIApplication.shared.isIdleTimerDisabled = true
        Task.detached(priority: .userInitiated) {
            do {
                let (nj, out) = try await up.run(j) { d, t, per in
                    DispatchQueue.main.async { done = d; total = t; perFrame = per }
                }
                if let out {
                    let msg = await VideoUpscaler.save(out, to: nj.options.saveTo)
                    nj.finish()
                    await MainActor.run { job = nil; tick += 1; message = "Selesai: \(out.lastPathComponent). \(msg)" }
                } else {
                    await MainActor.run {
                        job = nj
                        message = "Dijeda di \(nj.done)/\(nj.frames) frame. Tekan Lanjutkan (atau otomatis saat kembali ke app)."
                    }
                }
            } catch {
                await MainActor.run { job = AIJob.load(); message = error.localizedDescription }
            }
            await MainActor.run {
                running = false
                UIApplication.shared.isIdleTimerDisabled = false
                endBg()
                // kembali ke app sebelum potongan selesai disimpan -> lanjut sekarang
                if autoResume, UIApplication.shared.applicationState == .active, let j2 = job {
                    autoResume = false
                    start(j2)
                }
            }
        }
    }
}
