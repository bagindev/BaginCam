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

struct UpscaleOptions {
    var model: SRModel = .fast
    var mode: UpscaleMode = .enlarge
    var strength: Double = 0.8
    var stabilize = true
    var saveTo: VideoSaveTo = .photos
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
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func cancel() { cancelled = true }

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

    /// progress(selesai, total, detik per frame). Mengembalikan URL hasil (folder Documents/Videos).
    func run(_ url: URL, _ o: UpscaleOptions, progress: @escaping (Int, Int, Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw UpscaleError.msg("Tidak ada trek video") }
        if try await Self.isLog(vTrack) { throw UpscaleError.msg("Apple Log belum didukung") }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let info = try await Self.inspect(url, o)
        guard let sr = SRUpscaler(model: o.model) else { throw UpscaleError.msg("Model AI \(o.model.rawValue) tidak ada") }

        // komposisi: putar sesuai orientasi + HDR -> Rec.709
        let comp = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let w = Int(comp.renderSize.width), h = Int(comp.renderSize.height)
        let k = Self.outScale(w: w, h: h, mode: o.mode)
        let ow = Self.even(Double(w) * k), oh = Self.even(Double(h) * k)

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = comp
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw UpscaleError.msg("Video tidak bisa dibaca") }
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let aTrack {
            let a = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            if reader.canAdd(a) { reader.add(a); aOut = a }
        }

        let base = url.deletingPathExtension().lastPathComponent
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = k > 1 ? String(format: "AI%.1fx", k) : "AIsharp"
        let outURL = dir.appendingPathComponent("\(base)_\(tag)_\(o.model == .fast ? "C" : "D").mov")
        try? FileManager.default.removeItem(at: outURL)

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
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
        var aIn: AVAssetWriterInput?
        if aOut != nil, let aTrack, let hint = try await aTrack.load(.formatDescriptions).first {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            a.expectsMediaDataInRealTime = false
            if writer.canAdd(a) { writer.add(a); aIn = a }
        }

        guard reader.startReading() else { throw UpscaleError.msg("Baca gagal: \(reader.error?.localizedDescription ?? "-")") }
        guard writer.startWriting() else { throw UpscaleError.msg("Tulis gagal: \(writer.error?.localizedDescription ?? "-")") }
        writer.startSession(atSourceTime: .zero)
        Log.sr.info("AI video: \(url.lastPathComponent, privacy: .public) \(w, privacy: .public)x\(h, privacy: .public) -> \(ow, privacy: .public)x\(oh, privacy: .public), \(info.frames, privacy: .public) frame, model \(o.model.rawValue, privacy: .public), kedip \(o.stabilize, privacy: .public)")

        // audio berjalan bersamaan (writer menyisipkan audio & video)
        let audioDone = DispatchSemaphore(value: 0)
        let audioQueue = DispatchQueue(label: "bagincam.ai.audio")
        if let aIn, let aOut {
            var finished = false
            aIn.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
                while aIn.isReadyForMoreMediaData && !finished {
                    if self?.cancelled ?? true { finished = true; aIn.markAsFinished(); audioDone.signal(); return }
                    if let sb = aOut.copyNextSampleBuffer() { aIn.append(sb) } else {
                        finished = true; aIn.markAsFinished(); audioDone.signal(); return
                    }
                }
            }
        } else {
            audioDone.signal()
        }

        var prevBase: CIImage?, prevSR: CIImage?
        var prevCG: CGImage?, prevSRCG: CGImage?
        var done = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        var failure: String?
        while !cancelled {
            let ok: Bool = autoreleasepool {
                guard let sb = vOut.copyNextSampleBuffer() else { return false }
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { return true }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let src = CIImage(cvPixelBuffer: pb)
                guard let cg = ci.createCGImage(src, from: src.extent, format: .BGRA8, colorSpace: srgb),
                      let up = sr.upscale(cg, crop: CGRect(x: 0, y: 0, width: cg.width, height: cg.height), outScale: k) else {
                    failure = "AI gagal di frame \(done + 1): \(sr.lastError ?? "-")"
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

                while !vIn.isReadyForMoreMediaData && !cancelled { usleep(3000) }
                guard !cancelled, let pool = adaptor.pixelBufferPool else { return false }
                var dst: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
                guard let dst else { failure = "buffer penuh"; return false }
                ci.render(out, to: dst, bounds: CGRect(x: 0, y: 0, width: ow, height: oh), colorSpace: srgb)
                if !adaptor.append(dst, withPresentationTime: pts) {
                    failure = "tulis frame gagal: \(writer.error?.localizedDescription ?? "-")"
                    return false
                }
                done += 1
                let per = (CFAbsoluteTimeGetCurrent() - t0) / Double(done)
                progress(done, max(info.frames, done), per)
                return true
            }
            if !ok { break }
        }
        _ = prevCG; _ = prevSRCG

        if cancelled || failure != nil {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            throw UpscaleError.msg(failure ?? "Dibatalkan")
        }
        vIn.markAsFinished()
        _ = audioDone.wait(timeout: .now() + 60)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw UpscaleError.msg("Simpan gagal: \(writer.error?.localizedDescription ?? "-")")
        }
        let total = CFAbsoluteTimeGetCurrent() - t0
        Log.sr.info("AI video selesai: \(outURL.lastPathComponent, privacy: .public), \(done, privacy: .public) frame, \(total, format: .fixed(precision: 1), privacy: .public) s")
        return outURL
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

    private var appVideos: [URL] {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Videos")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Cepat = model ringan (~0,035 s/tile). Detail = lebih tajam tapi ~6x lebih lama. Kurangi kedip mencegah tekstur 'berdenyut', tapi pada gerakan cepat detail bisa sedikit lebih lembut.")
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
                        Text("Jangan tinggalkan app sampai selesai (layar tetap menyala).").font(.caption).foregroundStyle(.orange)
                        Button("Batal", role: .destructive) { upscaler?.cancel() }
                    } else {
                        Button { start() } label: { Label("Mulai AI Upscale", systemImage: "sparkles") }
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
        .onAppear {
            opt.model = cam.srModel
            opt.saveTo = cam.videoSaveTo
            cam.stop()                      // kamera berhenti: GPU / Neural Engine untuk AI
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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

    private func start() {
        guard let u = input else { return }
        let up = VideoUpscaler()
        upscaler = up
        running = true
        done = 0; total = info?.frames ?? 0; perFrame = 0
        message = ""
        UIApplication.shared.isIdleTimerDisabled = true
        let o = opt
        Task.detached(priority: .userInitiated) {
            do {
                let out = try await up.run(u, o) { d, t, per in
                    DispatchQueue.main.async { done = d; total = t; perFrame = per }
                }
                let msg = await VideoUpscaler.save(out, to: o.saveTo)
                await MainActor.run { message = "Selesai: \(out.lastPathComponent). \(msg)"; running = false }
            } catch {
                await MainActor.run { message = error.localizedDescription; running = false }
            }
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}
