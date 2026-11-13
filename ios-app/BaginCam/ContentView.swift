import SwiftUI
import CoreImage
import UniformTypeIdentifiers

/// Susunan ala GCam (v0.10): chip cepat di atas, bar info di preview, zoom di atas shutter,
/// baris shutter (thumbnail · shutter · balik kamera), mode MALAM · FOTO · PRO, laci Pro di kanan bawah.
struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @StateObject private var luts = LUTLibrary()
    @State private var renderer = PreviewRenderer()
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var showViewer = false
    @State private var showPro = false
    @State private var proControl: ProControl = .ev
    @State private var histogram: [Float] = []
    @State private var showHistogram = true
    @AppStorage("zebra") private var zebra = false
    @AppStorage("peaking") private var peaking = false
    @AppStorage("zebraLevel") private var zebraLevel = 0.95
    @AppStorage("peakColor") private var peakColor = "Merah"
    @State private var showUpscale = false
    @State private var focusPoint: CGPoint?      // posisi kotak fokus di preview (piksel view)
    @State private var focusTick = 0
    @State private var showGrid = false
    @State private var showLevel = true
    @StateObject private var level = LevelMonitor()
    @StateObject private var comp = CompositionAI()
    @State private var touch = TouchClock()
    @State private var pinchBase: Double?
    @State private var showAssist = false

    enum ProControl: String, CaseIterable, Identifiable {
        case ev = "EV", iso = "ISO", shutter = "Shutter", wb = "WB", focus = "Fokus", timer = "Timer"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .ev: return "plusminus.circle"
            case .iso: return "camera.aperture"
            case .shutter: return "timer"
            case .wb: return "thermometer.medium"
            case .focus: return "scope"
            case .timer: return "clock"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 6) {
                topBar
                preview
                if showsZoom { zoomRow }
                Spacer(minLength: 0)
                if showPro { proDrawer }
                if !CameraManager.usesVirtual(cam.mode) { lensRow }
                statusLine
                shutterRow
                modeRow
            }
            .padding(.horizontal, 12)
            if cam.idlePaused { idlePauseLayer }
        }
        .background(TouchSpyView { touch.mark() })
        .sheet(isPresented: $showSettings) {
            SettingsSheet(cam: cam, showHistogram: $showHistogram, zebra: $zebra, peaking: $peaking,
                          showGrid: $showGrid, showLevel: $showLevel, hasLUT: luts.selected != nil)
        }
        .sheet(isPresented: $showUpscale, onDismiss: { cam.pendingUpscale = nil }) {
            VideoUpscaleView(cam: cam, initial: cam.pendingUpscale)
        }
        .onChange(of: cam.pendingUpscale) { _, u in if u != nil && !showUpscale { showUpscale = true } }
        .fullScreenCover(isPresented: $showViewer, onDismiss: { if !cam.isRecording { cam.start() } }) {
            LibraryViewer(fallbackData: cam.lastImageData, fallbackName: cam.lastFileName)
        }
        .onAppear {
            let r = renderer
            cam.onFrame = { image in r.push(image) }
            let lv = level
            cam.motionLevel = { [weak lv] in lv?.rotationLevel ?? -1 }
            r.onHistogram = { bins in histogram = bins }
            r.zebra = zebra
            r.peaking = peaking
            r.zebraLevel = Float(zebraLevel)
            r.peakColor = Self.peakCI(peakColor)
            comp.onAutoZoom = { z in cam.setTotalZoom(cam.totalZoom * z) }
            cam.orientationAngle = { [weak lv] in lv?.angleNow ?? 90 }
            LibraryViewer.latestThumb { t in cam.showLibraryThumb(t) }
            updateComp()
            cam.start()
            level.start()
            if luts.selected == nil {
                luts.select(luts.items.first { $0.name.contains("STANDARD") } ?? luts.items.first)
            }
        }
        .onChange(of: luts.filter) { _, newFilter in renderer.lutFilter = newFilter; cam.captureLUT = luts.current }
        .onChange(of: cam.previewExtraZoom) { _, z in renderer.zoom = z }
        .onChange(of: cam.previewFrozen) { _, v in renderer.frozen = v }
        .onChange(of: zebra) { _, v in renderer.zebra = v }
        .onChange(of: peaking) { _, v in renderer.peaking = v }
        .onChange(of: zebraLevel) { _, v in renderer.zebraLevel = Float(v) }
        .onChange(of: peakColor) { _, v in renderer.peakColor = Self.peakCI(v) }
        .onChange(of: cam.previewSharpen) { _, v in renderer.sharpen = v }
        .onChange(of: level.steady) { _, v in cam.deviceSteady = v }
        .onChange(of: showHistogram) { _, v in renderer.histogramEnabled = v; if !v { histogram = [] } }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
            if case .success(let url) = result { luts.importLUT(from: url) }
        }
        .modifier(CompHooks(cam: cam, comp: comp, level: level, update: updateComp, maxZoom: { compMaxZoom }))
        .modifier(PowerHooks(cam: cam, level: level, touch: touch, busy: { showUpscale || showSettings || showViewer || showAssist },
                             histogram: { on in renderer.histogramEnabled = on && showHistogram; if !on { histogram = [] } }))
    }

    // MARK: - baris 1: chip cepat
    private var topBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if cam.shootMode == .video {
                        // v0.12.4: dikelompokkan (Format · LUT · WB · Bantu · AI · Senter)
                        videoFormatChip
                        colorGroupChip
                        assistChip
                        upscaleChip
                        torchChip
                    } else {
                        // v0.14: dikelompokkan (Proses · Hasil · Warna · Bantu · flash · Live)
                        processChip
                        resultChip
                        colorGroupChip
                        assistChip
                        if appleCapable && cam.flashAvailable { flashChip }
                        if appleCapable && cam.liveAvailable { liveChip }
                    }
                }
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .rotationEffect(uiRot).animation(.easeInOut(duration: 0.25), value: level.captureAngle)
                    .font(.body)
                    .frame(width: 34, height: 30)
                    .background(Color.white.opacity(0.16), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.top, 6)
    }

    /// v0.15: waktu sentuhan terakhir (kelas -> tidak memicu render ulang)
    final class TouchClock {
        private(set) var last = Date()
        func mark() { let n = Date(); if n.timeIntervalSince(last) > 0.5 { last = n } }
        var idle: TimeInterval { Date().timeIntervalSince(last) }
    }

    /// v0.15: hemat panas - jeda kamera saat tidak dipakai, histogram mati saat panas
    private struct PowerHooks: ViewModifier {
        @ObservedObject var cam: CameraManager
        @ObservedObject var level: LevelMonitor
        let touch: TouchClock
        let busy: () -> Bool
        let histogram: (Bool) -> Void
        func body(content: Content) -> some View {
            content
                .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                    guard !cam.idlePaused, !cam.isRecording, !cam.isCapturing, cam.countdown == 0, !busy() else { return }
                    // HP diletakkan diam 45 s tanpa disentuh, atau 3 menit tanpa disentuh
                    if (level.steady && touch.idle > 45) || touch.idle > 180 { cam.pauseIdle() }
                }
                .onChange(of: cam.thermal) { _, t in histogram(t < 2 || cam.isRecording) }
                .onChange(of: cam.isRecording) { _, _ in histogram(cam.thermal < 2 || cam.isRecording) }
        }
    }

    /// layar kamera dijeda
    private var idlePauseLayer: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "pause.circle").font(.system(size: 54)).foregroundStyle(.yellow)
                Text("Kamera dijeda").font(.headline).foregroundStyle(.white)
                Text("Tidak dipakai beberapa saat - dijeda supaya HP tidak panas.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                if cam.thermal >= 2 {
                    Label(cam.thermal >= 3 ? "Suhu kritis" : "Suhu HP panas", systemImage: "thermometer.high")
                        .font(.caption.bold()).foregroundStyle(.red)
                }
            }
            .padding(30)
        }
        .contentShape(Rectangle())
        .onTapGesture { touch.mark(); cam.resumeIdle() }
    }

    /// v0.15: ikon ikut berputar saat HP lanskap (layout tetap potret seperti kamera bawaan)
    private var uiRot: Angle { .degrees(Double(90 - level.captureAngle)) }

    /// v0.13: pemicu AI Komposisi dipisah dari body (body terlalu panjang untuk type-checker)
    private struct CompHooks: ViewModifier {
        @ObservedObject var cam: CameraManager
        let comp: CompositionAI
        @ObservedObject var level: LevelMonitor
        let update: () -> Void
        let maxZoom: () -> CGFloat
        func body(content: Content) -> some View {
            content
                .onChange(of: cam.compAI) { _, _ in update() }
                .onChange(of: cam.shootMode) { _, _ in update() }
                .onChange(of: cam.aiLensLock) { _, _ in update() }
                .onChange(of: cam.totalZoom) { _, _ in comp.maxZoom = maxZoom() }
                .onChange(of: level.roll) { _, v in comp.roll = v }
        }
    }

    // MARK: - AI Komposisi (v0.13)
    private var compActive: Bool { cam.compAI && cam.shootMode != .video }

    /// zoom tambahan yang boleh disarankan (lensa Auto: sampai 2x dari zoom sekarang, maks 10x)
    private var compMaxZoom: CGFloat {
        guard showsZoom else { return 1 }
        return max(1, min(2, min(cam.maxTotalZoom, 10) / max(cam.totalZoom, 0.1)))
    }

    private func updateComp() {
        comp.maxZoom = compMaxZoom
        if compActive {
            let c = comp
            renderer.onAnalysis = { [weak c] img in c?.push(img) }
        } else {
            renderer.onAnalysis = nil
            comp.close()
        }
    }

    private var compChip: some View {
        Menu {
            Button { cam.compAI.toggle() } label: { check("AI Komposisi (tombol Susun ulang)", cam.compAI) }
            Button { cam.compCrop.toggle() } label: { check("Simpan versi crop setelah jepret", cam.compCrop) }
            if cam.compAI {
                Button { comp.startScan() } label: { Label("Susun ulang sekarang", systemImage: "crop") }
            }
            Text("Susun ulang: pilih komposisi, geser HP ke titik oranye, zoom otomatis. Versi crop: foto kedua _CROP (horizon lurus + subjek di sepertiga), foto asli tetap.")
        } label: { chip(cam.compAI ? "Komposisi" : "", icon: "crop", on: cam.compAI) }
    }

    /// Live & flash di FOTO (bila nyala, jepretan memakai proses Apple)
    private var appleCapable: Bool { cam.shootMode == .photo }

    private func chip(_ text: String, icon: String, on: Bool = false) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(on ? .bold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(on ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
            .foregroundStyle(on ? .black : .white)
    }

    private func check(_ title: String, _ on: Bool, detail: String? = nil) -> some View {
        Group {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
            if let detail { Text(detail) }
        }
    }

    @ViewBuilder private var processChip: some View {
        switch cam.shootMode {
        case .photo:
            Menu {
                ForEach(CameraManager.PhotoProcess.allCases) { p in
                    Button { cam.setPhotoProcess(p) } label: { check(p.rawValue, cam.photoProcess == p, detail: p.detail) }
                }
            } label: {
                let forced = (cam.livePhoto || cam.flash == .on) && cam.photoProcess != .apple
                chip(cam.photoProcess.rawValue + (forced ? " → Apple" : ""),
                     icon: cam.photoProcess == .apple ? "apple.logo" : (cam.photoProcess == .auto ? "a.circle" : "sparkles"),
                     on: true)
            }
        case .night:
            chip("MALAM", icon: "moon.stars.fill", on: true)
        case .video:
            chip("VIDEO", icon: "video.fill", on: true)
        case .pro:
            Menu {
                ForEach(CameraManager.ProFormat.allCases) { f in
                    Button { cam.setProFormat(f) } label: { check(f.rawValue, cam.proFormat == f, detail: f.detail) }
                }
            } label: {
                chip(cam.proFormat.rawValue, icon: "camera.badge.ellipsis", on: true)
            }
        }
    }

    private var lutChip: some View {
        Menu {
            Button { luts.select(nil) } label: { check("Tanpa LUT", luts.selected == nil) }
            ForEach(luts.items) { item in
                Button { luts.select(item) } label: { check(item.name, luts.selected?.id == item.id) }
            }
            Divider()
            if cam.shootMode == .video {
                Toggle("Bakar LUT ke video (keluaran Rec.709)", isOn: $cam.bakeLUTVideo)
            } else {
                Toggle("Bakar LUT ke foto", isOn: $cam.bakeLUT)
            }
            Button("Import .cube...") { showImporter = true }
        } label: {
            chip(luts.selected.map { shortLUT($0.name) } ?? "LUT", icon: "camera.filters")
        }
    }

    /// v0.14: LUT + white balance dalam satu menu "Warna"
    private var colorGroupChip: some View {
        Menu {
            Menu("LUT: \(luts.selected.map { shortLUT($0.name) } ?? "Tanpa")") {
                Button { luts.select(nil) } label: { check("Tanpa LUT", luts.selected == nil) }
                ForEach(luts.items) { item in
                    Button { luts.select(item) } label: { check(item.name, luts.selected?.id == item.id) }
                }
                Divider()
                if cam.shootMode == .video {
                    Toggle("Bakar LUT ke video (keluaran Rec.709)", isOn: $cam.bakeLUTVideo)
                } else {
                    Toggle("Bakar LUT ke foto", isOn: $cam.bakeLUT)
                }
                Button("Import .cube...") { showImporter = true }
            }
            if cam.shootMode != .video {
                Menu("Gaya warna: \(cam.colorStyle.rawValue)") {
                    ForEach(ColorStyle.allCases) { st in
                        Button { cam.colorStyle = st } label: { check(st.rawValue, cam.colorStyle == st, detail: st.detail) }
                    }
                    Text("Untuk HDR+, MALAM, Super Res, AI Zoom (bukan proses Apple)")
                }
            }
            Menu("White balance: \(wbText)") {
                ForEach(CameraManager.WBPreset.allCases) { p in
                    Button { cam.setWBPreset(p) } label: {
                        check(p.rawValue + (p.kelvin.map { " \(Int($0))K" } ?? ""), !cam.manualWB && cam.wbPreset == p)
                    }
                }
                Button { showPro = true; proControl = .wb } label: { check("Manual (Kelvin)...", cam.manualWB) }
            }
        } label: {
            chip((cam.shootMode != .video && cam.colorStyle != .natural ? cam.colorStyle.rawValue + " · " : "")
                 + "\(luts.selected.map { shortLUT($0.name) } ?? "LUT") · \(wbText)", icon: "camera.filters",
                 on: luts.selected != nil || cam.manualWB || cam.wbPreset != .auto || (cam.shootMode != .video && cam.colorStyle != .natural))
        }
    }

    private var wbText: String {
        cam.manualWB ? "\(Int(cam.temperature))K" : (cam.wbPreset == .auto ? "AWB" : cam.wbPreset.rawValue)
    }

    /// v0.14: format + resolusi + rasio + preset Tuning dalam satu menu "Hasil"
    private var resultChip: some View {
        Menu {
            if cam.mode == .hdrplus {
                Menu("Format: \(cam.outputFormat.rawValue)") {
                    ForEach(PhotoFormat.allCases) { f in
                        Button { cam.outputFormat = f } label: { check(f.rawValue, cam.outputFormat == f) }
                    }
                }
            }
            if SettingsSheet.showsResolution(cam) {
                Menu("Resolusi: \(cam.outputMP.label)") {
                    ForEach(OutputMP.allCases) { r in
                        Button { cam.outputMP = r } label: { check(r.label, cam.outputMP == r) }
                    }
                }
            }
            Menu("Rasio: \(cam.aspect.rawValue)") {
                ForEach(AspectRatio.allCases) { a in
                    Button { cam.aspect = a } label: { check(a.rawValue, cam.aspect == a) }
                }
                Text("Hanya HEIF/JPEG; RAW tetap 4:3")
            }
            if cam.mode == .hdrplus || cam.mode == .aiZoom || cam.mode == .heif {
                Menu("Tuning: \(tuningName)") {
                    ForEach(PhotoTuning.presets.indices, id: \.self) { i in
                        let p = PhotoTuning.presets[i]
                        Button { cam.tuning = p.1 } label: { check(p.0, cam.tuning == p.1) }
                    }
                    Button("Atur slider (ala AGC)...") { showSettings = true }
                }
            }
            Button("Pengaturan lain...") { showSettings = true }
        } label: {
            chip(formatText + (cam.aspect == .r43 ? "" : " · \(cam.aspect.rawValue)") + (cam.tuning.isDefault ? "" : " · T"),
                 icon: "photo")
        }
    }

    private var tuningName: String {
        PhotoTuning.presets.first { $0.1 == cam.tuning }.map { String($0.0.split(separator: " ").first ?? "") } ?? "Kustom"
    }

    private func shortLUT(_ n: String) -> String {
        n.replacingOccurrences(of: "SonyLook_", with: "").replacingOccurrences(of: "_100", with: "")
    }

    private var wbChip: some View {
        Menu {
            ForEach(CameraManager.WBPreset.allCases) { p in
                Button { cam.setWBPreset(p) } label: {
                    check(p.rawValue + (p.kelvin.map { " \(Int($0))K" } ?? ""), !cam.manualWB && cam.wbPreset == p)
                }
            }
            Button { showPro = true; proControl = .wb } label: { check("Manual (Kelvin)...", cam.manualWB) }
        } label: {
            chip(cam.manualWB ? "\(Int(cam.temperature))K" : (cam.wbPreset == .auto ? "AWB" : cam.wbPreset.rawValue),
                 icon: "thermometer.medium")
        }
    }

    private var formatText: String {
        switch cam.mode {
        case .proraw: return "ProRAW \(cam.outputMP.label)"
        case .bayer: return "Bayer DNG"
        case .hdrplus:
            return cam.outputFormat == .dng ? "DNG" : "\(cam.outputMP.label) · \(cam.outputFormat.rawValue)"
        default: return "\(cam.outputMP.label) · HEIF"
        }
    }

    private var formatChip: some View {
        Menu {
            if cam.mode == .hdrplus {
                Section("Format") {
                    ForEach(PhotoFormat.allCases) { f in
                        Button { cam.outputFormat = f } label: { check(f.rawValue, cam.outputFormat == f) }
                    }
                }
            }
            if SettingsSheet.showsResolution(cam) {
                Section("Resolusi") {
                    ForEach(OutputMP.allCases) { r in
                        Button { cam.outputMP = r } label: { check(r.label, cam.outputMP == r) }
                    }
                }
            }
            Button("Pengaturan lain...") { showSettings = true }
        } label: {
            chip(formatText, icon: "photo")
        }
    }

    private var ratioChip: some View {
        Menu {
            ForEach(AspectRatio.allCases) { a in
                Button { cam.aspect = a } label: { check(a.rawValue, cam.aspect == a) }
            }
            Text("Hanya HEIF/JPEG; RAW tetap 4:3")
        } label: {
            chip(cam.aspect.rawValue, icon: "aspectratio")
        }
    }

    private var flashChip: some View {
        Menu {
            ForEach(CameraManager.FlashSetting.allCases) { f in
                Button { cam.flash = f } label: { check(f.rawValue, cam.flash == f) }
            }
            Text("Flash nyala = jepretan memakai proses Apple")
        } label: {
            chip("", icon: cam.flash.icon, on: cam.flash != .off)
        }
    }

    private var liveChip: some View {
        Button { cam.setLivePhoto(!cam.livePhoto) } label: {
            chip("", icon: cam.livePhoto ? "livephoto" : "livephoto.slash", on: cam.livePhoto)
        }
        .disabled(cam.isCapturing)
    }

    // MARK: - chip VIDEO (ala Blackmagic + GCam)
    private var fpsText: String {
        cam.videoFps == .auto ? "Auto" : (cam.videoFps.isSlowMo ? "\(cam.videoFps.label) slow-mo" : "\(cam.videoFps.label) fps")
    }

    /// v0.12.4: satu menu Format = resolusi · fps · time-lapse · codec · warna · stabilisasi
    private var videoFormatChip: some View {
        Menu {
            Menu("Resolusi: \(cam.videoRes.rawValue)") {
                ForEach(VideoRes.allCases) { r in
                    Button { cam.videoRes = r } label: { check(r.rawValue, cam.videoRes == r) }
                }
            }
            Menu("Frame rate: \(cam.timelapse > 1 ? "time-lapse" : fpsText)") {
                ForEach(VideoFps.allCases) { f in
                    Button { cam.videoFps = f; cam.timelapse = 1 } label: {
                        check(f == .auto ? "Auto (60 terang / 30 gelap)" : (f.isSlowMo ? "\(f.label) slow-mo" : "\(f.label) fps"),
                              cam.videoFps == f && cam.timelapse <= 1)
                    }
                }
                if cam.videoFps.isSlowMo && cam.timelapse <= 1 {
                    Section("Slow-mo diputar di") {
                        ForEach([24, 30], id: \.self) { p in
                            Button { cam.slowPlayback = p } label: { check("\(p) fps (\(cam.videoFps.rawValue / p)x lebih lambat)", cam.slowPlayback == p) }
                        }
                    }
                }
            }
            Menu("Time-lapse: \(cam.timelapse > 1 ? "\(cam.timelapse)x" : "Mati")") {
                Button { cam.timelapse = 1 } label: { check("Mati", cam.timelapse <= 1) }
                ForEach([5, 10, 30, 60, 120], id: \.self) { k in
                    Button { cam.timelapse = k } label: { check("\(k)x (diputar 30 fps)", cam.timelapse == k) }
                }
            }
            Menu("Codec: \(cam.videoCodec.short)") {
                ForEach(VideoCodec.allCases) { c in
                    Button { cam.videoCodec = c } label: { check(c.rawValue, cam.videoCodec == c) }
                }
                Text("ProRes 4K ~5-6 GB/menit")
            }
            Menu("Warna: \(cam.videoColor.short)") {
                ForEach(VideoColor.allCases) { c in
                    Button { cam.videoColor = c } label: { check(c.rawValue, cam.videoColor == c) }
                }
                Text("Log: preview otomatis dikonversi ke Rec.709")
            }
            Menu("Stabilisasi: \(cam.videoStab.rawValue)") {
                ForEach(VideoStab.allCases) { st in
                    Button { cam.videoStab = st } label: { check(st.rawValue, cam.videoStab == st, detail: st.detail) }
                }
            }
        } label: {
            let rate = cam.timelapse > 1 ? "TL \(cam.timelapse)x" : cam.videoFps.label
            chip("\(cam.videoRes.rawValue) · \(rate) · \(cam.videoCodec.short) · \(cam.videoColor.short)", icon: "video", on: true)
        }
        .disabled(cam.isRecording)
    }

    static let peakColors = ["Merah", "Kuning", "Hijau", "Biru", "Putih"]
    static func peakCI(_ n: String) -> CIColor {
        switch n {
        case "Kuning": return CIColor(red: 1, green: 0.9, blue: 0)
        case "Hijau": return CIColor(red: 0.1, green: 1, blue: 0.2)
        case "Biru": return CIColor(red: 0.2, green: 0.5, blue: 1)
        case "Putih": return CIColor(red: 1, green: 1, blue: 1)
        default: return CIColor(red: 1, green: 0.15, blue: 0.1)
        }
    }

    /// focus peaking + zebra (ala Blackmagic), hanya di layar
    /// v0.17: Bantu = panel geser dari bawah (menu lama terlalu panjang, tidak bisa di-scroll)
    private var assistChip: some View {
        Button { showAssist = true } label: {
            let video = cam.shootMode == .video
            let n = (peaking ? 1 : 0) + (zebra ? 1 : 0) + (video && cam.frameGuide != .off ? 1 : 0)
                + (!video && cam.compAI ? 1 : 0)
            chip(n > 0 ? "Bantu \(n)" : "Bantu", icon: "scope", on: n > 0)
        }
        .sheet(isPresented: $showAssist) {
            AssistPanel(cam: cam, comp: comp, peaking: $peaking, peakColor: $peakColor, zebra: $zebra,
                        zebraLevel: $zebraLevel, showGrid: $showGrid, showLevel: $showLevel,
                        showHistogram: $showHistogram) { showAssist = false }
        }
    }

    /// AI video: tidak bisa real-time -> "AI setelah rekam" (nyala/mati) + buka AI Upscale manual
    private var upscaleChip: some View {
        Menu {
            Button { cam.aiAfterRecord.toggle() } label: {
                check("AI setelah rekam (otomatis buka)", cam.aiAfterRecord)
            }
            Button { showUpscale = true } label: { Label("Buka AI Upscale...", systemImage: "sparkles") }
            Text("AI terlalu berat untuk real-time; diproses setelah rekam (~1-2 s/frame)")
        } label: { chip(cam.aiAfterRecord ? "AI ON" : "AI", icon: "sparkles", on: cam.aiAfterRecord) }
        .disabled(cam.isRecording)
    }

    private var torchChip: some View {
        Button { cam.torch.toggle() } label: {
            chip("", icon: cam.torch ? "flashlight.on.fill" : "flashlight.off.fill", on: cam.torch)
        }
    }

    /// garis bingkai (2.39 / 1.85 / ...), mengikuti cara HP dipegang
    @ViewBuilder private var frameGuideOverlay: some View {
        if cam.shootMode == .video, let r = cam.frameGuide.ratio {
            GeometryReader { g in
                let landscape = abs(cam.horizonAngle - 90) > 45 && abs(cam.horizonAngle - 270) > 45
                let a = landscape ? 1 / r : r                      // lebar / tinggi di layar
                let full = CGRect(origin: .zero, size: g.size)
                let w = min(g.size.width, g.size.height * a), h = w / a
                let box = CGRect(x: (g.size.width - w) / 2, y: (g.size.height - h) / 2, width: w, height: h)
                ZStack {
                    Path { p in p.addRect(full); p.addRect(box) }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    Path { p in p.addRect(box) }.stroke(Color.yellow.opacity(0.8), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// meter level mikrofon (dB)
    private var audioMeter: some View {
        let v = CGFloat(max(0, min(1, (cam.audioLevel + 60) / 60)))
        return HStack(spacing: 4) {
            Image(systemName: "mic.fill").font(.caption2)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(cam.audioLevel > -6 ? Color.red : (cam.audioLevel > -18 ? Color.yellow : Color.green))
                    .frame(width: 50 * v)
            }
            .frame(width: 50, height: 6)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }

    private var recordTimeText: String {
        let s = Int(cam.recordSeconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// v0.12.4: timer rekam besar (ala Blackmagic) - selalu terlihat, merah saat merekam
    private var recTimer: some View {
        HStack(spacing: 6) {
            Circle().fill(cam.isRecording ? Color.white : Color.red).frame(width: 9, height: 9)
            Text(recordTimeText).font(.system(.callout, design: .monospaced).bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(cam.isRecording ? Color.red : Color.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
        .fixedSize()
    }

    private var videoInfoRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                lensBadge.frame(maxWidth: .infinity, alignment: .leading)
                recTimer
                audioMeter.frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: 6) {
                if !cam.isRecording && !cam.videoInfo.isEmpty { infoPill(cam.videoInfo, icon: "video") }
                if !cam.zoomQuality.isEmpty && (cam.zoomQuality != "Native" || cam.totalZoom > 1.05) {
                    infoPill(cam.zoomQuality, icon: cam.zoomQuality == "Native" ? "sparkle" : "plus.magnifyingglass",
                             color: cam.zoomQuality == "Native" ? .green : .orange)
                }
                if cam.needND { infoPill("ND", icon: "sun.max.fill", color: .orange) }
                if cam.thermal >= 2 { infoPill(cam.thermal >= 3 ? "Kritis" : "Panas", icon: "thermometer.high", color: .red) }
                if cam.timerSeconds > 0 && !cam.isRecording { infoPill("\(cam.timerSeconds)s", icon: "clock") }
                Spacer(minLength: 0)
                if cam.minutesLeft > 0 { infoPill("\(cam.minutesLeft) mnt", icon: "internaldrive") }
            }
        }
        .padding(8)
    }

    // MARK: - preview + baris 2 (info)
    private var preview: some View {
        MetalPreview(renderer: renderer, onHardwareShutter: { touch.mark(); if cam.idlePaused { cam.resumeIdle() } else { cam.shutterPressed() } },
                     fps: cam.thermal >= 2 && !cam.isRecording ? 20 : 30)
            .aspectRatio(cam.shootMode == .video ? 9.0 / 16.0 : 3.0 / 4.0, contentMode: .fit)
            .clipped()
            .overlay { ratioMask }
            .overlay { frameGuideOverlay }
            .overlay(alignment: .bottomLeading) { readout }
            .overlay(alignment: .topTrailing) {
                if showHistogram && !histogram.isEmpty { HistogramView(bins: histogram).padding(.top, cam.shootMode == .video ? 72 : 40).padding(8) }
            }
            .overlay(alignment: .bottomTrailing) { assistBadges }
            .overlay { if showGrid { GridOverlay().allowsHitTesting(false) } }
            .overlay { if showLevel { LevelOverlay(level: level) } }
            .overlay { countdownLayer }
            .overlay { focusLayer }
            .overlay { if compActive && !cam.isCapturing { CompositionOverlay(comp: comp) } }
            .overlay(alignment: .top) {
                if cam.shootMode == .video { videoInfoRow } else { infoRow }
            }
    }

    /// area di luar rasio foto digelapkan (seperti kamera bawaan)
    @ViewBuilder private var ratioMask: some View {
        if cam.aspect != .r43 && cam.shootMode != .video {
            GeometryReader { g in
                let full = CGRect(origin: .zero, size: g.size)
                let r = cam.aspect.rect(in: full)
                Path { p in
                    p.addRect(full)
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)
        }
    }

    private var infoRow: some View {
        HStack(spacing: 6) {
            lensBadge
            if showsZoom { zoomChip }
            if let f = framesText { infoPill(f, icon: cam.shootMode == .night && level.steady ? "camera.on.rectangle" : "square.stack.3d.up") }
            Spacer(minLength: 0)
            if nightSuggest {
                Button { cam.setShootMode(.night) } label: { infoPill("MALAM?", icon: "moon.stars.fill", color: .yellow) }
            }
            if cam.aeafLocked { infoPill("", icon: "lock.fill", color: .yellow) }
            if cam.timerSeconds > 0 { infoPill("\(cam.timerSeconds)s", icon: "clock") }
            if cam.evBias != 0 && !cam.manualExposure { infoPill(String(format: "%+.1f", cam.evBias), icon: "plusminus") }
        }
        .padding(8)
    }

    private func infoPill(_ text: String, icon: String, color: Color = .white) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.caption.bold())
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(color)
    }

    /// saran mode MALAM saat gelap (seperti ikon ★A GCam)
    private var nightSuggest: Bool {
        cam.shootMode == .photo && Double(cam.liveISO) * cam.liveShutter >= 10
    }

    /// perkiraan frame HDR+ / rencana MALAM
    private var framesText: String? {
        guard cam.mode == .hdrplus, cam.shootMode != .pro || cam.proFormat == .hdrplus else { return nil }
        if cam.shootMode == .night {
            let p = CameraManager.nightPlan(iso: cam.liveISO, shutter: cam.liveShutter, minISO: cam.isoRange.lowerBound,
                                            steady: level.steady, tele: cam.activeLensLabel.hasPrefix("Tele"))
            return "\(p.frames)×\(Self.shutterText(p.shutter))"
        }
        return "\(cam.autoFrames ? cam.autoFrameCount() : cam.burstCount)f"
    }

    private var readout: some View {
        Text("ISO \(Int(cam.liveISO))  \(Self.shutterText(cam.liveShutter))  \(Int(cam.liveTemp))K  F\(String(format: "%.2f", cam.liveLens))")
            .font(.caption.monospacedDigit())
            .padding(6)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(cam.isAuto ? .white : .yellow)
            .padding(8)
    }

    /// lensa fisik yang dipakai (mis. "Tele 5x", "Utama 1x · crop 7.0x"), + ikon makro
    private var lensBadge: some View {
        HStack(spacing: 4) {
            if cam.macroActive { Image(systemName: "camera.macro") }
            Text(cam.activeLensLabel)
        }
        .font(.caption.bold())
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(cam.activeLensLabel.contains("crop") ? .orange : .yellow)
    }

    /// cara zoom + AI (dipakai bila zoom melewati lensa optik)
    private var zoomChip: some View {
        Menu {
            Section("Cara zoom (melewati lensa optik)") {
                ForEach(CameraManager.ZoomMethod.allCases) { z in
                    Button { cam.zoomMethod = z } label: { check(z.rawValue, cam.zoomMethod == z, detail: z.detail) }
                }
            }
            Section("AI setelah zoom") {
                Toggle("AI", isOn: $cam.zoomAIEnabled)
                if cam.zoomAIEnabled {
                    ForEach(SRModel.allCases) { m in
                        Button { cam.srModel = m } label: { check("Model \(m.rawValue)", cam.srModel == m) }
                    }
                    Toggle("Fokus tulisan (OCR)", isOn: $cam.textFocus)
                }
            }
            Button("Kekuatan AI & lainnya...") { showSettings = true }
        } label: {
            let ai = cam.zoomAIEnabled ? " + AI \(cam.srModel.rawValue)" : ""
            Text(cam.zoomMethod.rawValue + ai)
                .font(.caption.bold())
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(cam.zoomAIEnabled ? Color.yellow.opacity(0.9) : Color.black.opacity(0.55), in: Capsule())
                .foregroundStyle(cam.zoomAIEnabled ? .black : .white)
        }
    }

    /// ikon kecil zebra / peaking aktif (ketuk = buka pengaturan)
    @ViewBuilder private var assistBadges: some View {
        if zebra || peaking {
            HStack(spacing: 6) {
                if zebra { Image(systemName: "line.diagonal") }
                if peaking { Image(systemName: "scope") }
            }
            .font(.caption.bold())
            .padding(6)
            .background(.black.opacity(0.5), in: Capsule())
            .foregroundStyle(.yellow)
            .padding(8)
            .onTapGesture { showSettings = true }
        }
    }

    // MARK: - zoom
    /// zoom tersedia di mode kamera virtual (lensa belakang)
    private var showsZoom: Bool {
        CameraManager.usesVirtual(cam.mode) ? cam.aiLensLock != .front : false
    }

    private var minZoom: Double {
        switch cam.aiLensLock {
        case .tele?: return 5
        case .ultraWide?: return 0.5
        case nil: return Double(cam.minAutoZoom)
        default: return 1
        }
    }
    private var maxZoom: Double { Double(cam.maxTotalZoom) }
    private var displayZoom: Double { Double(cam.totalZoom) }

    private func setDisplayZoom(_ z: Double) { cam.setTotalZoom(CGFloat(z)) }

    /// slider 0..1 -> zoom min..max skala logaritmik
    private var zoomBinding: Binding<Double> {
        Binding(
            get: { log(displayZoom / minZoom) / log(max(maxZoom / minZoom, 1.01)) },
            set: { t in setDisplayZoom(minZoom * pow(max(maxZoom / minZoom, 1.01), t)) })
    }

    private var zoomPresets: [Double] {
        if cam.shootMode == .video && !cam.nativeZoomPoints.isEmpty {
            // video: titik native (lensa + crop sensor 48 MP) + 10x
            var p = cam.nativeZoomPoints.map { Double($0) }
            if !p.contains(where: { abs($0 - 10) < 0.5 }) { p.append(10) }
            return p.sorted().filter { $0 >= minZoom - 0.01 && $0 <= maxZoom + 0.01 }
        }
        return [0.5, 1, 2, 5, 10, 25, 50].filter { $0 >= minZoom - 0.01 && $0 <= maxZoom + 0.01 }
    }

    private func isNative(_ z: Double) -> Bool {
        cam.shootMode == .video && cam.nativeZoomPoints.contains { abs(Double($0) - z) < 0.01 }
    }

    private func zoomLabel(_ z: Double) -> String {
        let t = z < 1 ? String(format: ".%.0f", z * 10) : (abs(z - z.rounded()) < 0.05 ? String(format: "%.0f", z) : String(format: "%.1f", z))
        return t + (isNative(z) ? "✦" : "x")
    }

    private var zoomRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(zoomPresets, id: \.self) { z in
                    let on = abs(displayZoom - z) < 0.05
                    Button { setDisplayZoom(z) } label: {
                        Text(zoomLabel(z)).rotationEffect(uiRot).animation(.easeInOut(duration: 0.25), value: level.captureAngle)
                    }
                        .font(.caption.bold())
                        .frame(width: 40, height: 28)
                        .background(on ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(on ? .black : .white)
                }
                Spacer(minLength: 0)
                Text(String(format: "%.1fx", displayZoom))
                    .font(.callout.monospacedDigit().bold()).foregroundStyle(.yellow)
            }
            Slider(value: zoomBinding, in: 0...1).tint(.yellow)
            if cam.autoLensAvailable { lockRow }
        }
    }

    private var lockRow: some View {
        HStack(spacing: 6) {
            Image(systemName: cam.aiLensLock == nil ? "lock.open" : "lock.fill")
                .font(.caption2).foregroundStyle(cam.aiLensLock == nil ? .white.opacity(0.7) : .yellow)
            ForEach(lockOptions, id: \.self) { l in
                let on = cam.aiLensLock == l
                Button(lockLabel(l)) { cam.setAILensLock(l) }
                    .font(.caption2.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(on ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(on ? .black : .white)
                    .disabled(cam.isCapturing || cam.isRecording)
            }
            Spacer(minLength: 0)
            if cam.isRecording && cam.aiLensLock == nil {
                Text("ganti lensa: tombol zoom").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var lockOptions: [CameraManager.Lens?] {
        var o: [CameraManager.Lens?] = [nil]
        for l in [CameraManager.Lens.ultraWide, .wide, .tele] where cam.availableLenses.contains(l) { o.append(l) }
        return o
    }

    private func lockLabel(_ l: CameraManager.Lens?) -> String {
        switch l {
        case nil: return "Auto"
        case .ultraWide?: return "UW .5x"
        case .wide?: return "Utama 1x"
        case .tele?: return "Tele 5x"
        case .front?: return "Depan"
        }
    }

    // MARK: - timer / capture
    @ViewBuilder private var countdownLayer: some View {
        if cam.countdown > 0 {
            Text("\(cam.countdown)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 8)
                .onTapGesture { cam.cancelCountdown() }
        } else if cam.previewFrozen {
            Text(cam.captureHint.isEmpty ? "Memotret - tahan HP..." : cam.captureHint)
                .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.yellow)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 44)
                .allowsHitTesting(false)
        }
    }

    // MARK: - sentuh fokus
    private var focusLayer: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { loc in
                        tapFocus(loc, size: geo.size, lock: false)
                    }
                    .gesture(LongPressGesture(minimumDuration: 0.6).sequenced(before: DragGesture(minimumDistance: 0))
                        .onEnded { value in
                            if case .second(true, let drag?) = value {
                                tapFocus(drag.location, size: geo.size, lock: true)
                            }
                        })
                    // v0.16: cubit untuk zoom (seperti kamera bawaan)
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { v in
                            guard showsZoom, !cam.isCapturing else { return }
                            if pinchBase == nil { pinchBase = displayZoom }
                            setDisplayZoom(min(maxZoom, max(minZoom, (pinchBase ?? displayZoom) * Double(v.magnification))))
                        }
                        .onEnded { _ in pinchBase = nil })
                if let p = focusPoint {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 76, height: 76)
                        .position(p)
                        .allowsHitTesting(false)
                }
                if cam.aeafLocked {
                    Text("AE/AF TERKUNCI")
                        .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.yellow, in: Capsule()).foregroundStyle(.black)
                        .position(x: geo.size.width / 2, y: 60)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func tapFocus(_ loc: CGPoint, size: CGSize, lock: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        // v0.17: sentuhan di luar preview (baris zoom di bawahnya) bukan fokus
        guard loc.x >= 0, loc.y >= 0, loc.x <= size.width, loc.y <= size.height else { return }
        focusPoint = loc
        focusTick += 1
        let tick = focusTick
        cam.focus(atViewPoint: CGPoint(x: loc.x / size.width, y: loc.y / size.height), lock: lock)
        DispatchQueue.main.asyncAfter(deadline: .now() + (lock ? 2.5 : 1.2)) {
            if focusTick == tick { focusPoint = nil }
        }
    }

    // MARK: - lensa fisik (PRO ProRAW / Bayer)
    private var lensRow: some View {
        HStack(spacing: 14) {
            ForEach(cam.availableLenses) { l in
                Button { cam.setLens(l) } label: {
                    Group {
                        if l == .front { Image(systemName: "person.crop.circle") } else { Text(l.rawValue) }
                    }
                    .font(.footnote.bold())
                    .frame(width: 44, height: 44)
                    .background(cam.lens == l ? Color.yellow : Color.white.opacity(0.15), in: Circle())
                    .foregroundStyle(cam.lens == l ? .black : .white)
                }
                .disabled(cam.isCapturing)
            }
        }
    }

    // MARK: - laci Pro (ala GCam)
    private var proDrawer: some View {
        VStack(spacing: 8) {
            proRuler
            HStack(spacing: 0) {
                ForEach(ProControl.allCases) { c in
                    Button { proControl = c } label: {
                        VStack(spacing: 2) {
                            Image(systemName: c.icon).font(.body)
                            Text(c.rawValue).font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(proControl == c ? Color.yellow.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            if isManual(c) { Circle().fill(Color.yellow).frame(width: 6, height: 6).padding(4) }
                        }
                    }
                    .foregroundStyle(proControl == c ? .yellow : .white)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }

    private func isManual(_ c: ProControl) -> Bool {
        switch c {
        case .ev: return cam.evBias != 0
        case .iso, .shutter: return cam.manualExposure
        case .wb: return cam.manualWB
        case .focus: return cam.manualFocus
        case .timer: return cam.timerSeconds > 0
        }
    }

    @ViewBuilder private var proRuler: some View {
        switch proControl {
        case .ev:
            ruler("EV", String(format: "%+.1f", cam.evBias), manual: cam.evBias != 0, reset: { cam.setEVBias(0) }) {
                Slider(value: Binding(get: { cam.evBias }, set: { cam.setEVBias((($0 * 10).rounded()) / 10) }), in: -3...3)
                    .disabled(cam.manualExposure)
            }
        case .iso:
            ruler("ISO", "\(Int(cam.manualExposure ? cam.iso : cam.liveISO))", manual: cam.manualExposure,
                  reset: { cam.setManual(exposure: false) }) {
                Slider(value: Binding(get: { cam.manualExposure ? cam.iso : cam.liveISO },
                                      set: { v in
                                          if !cam.manualExposure { cam.setManual(exposure: true) }
                                          cam.iso = v
                                          cam.applyManual()
                                      }), in: cam.isoRange)
            }
        case .shutter:
            ruler("Shutter", Self.shutterText(cam.manualExposure ? cam.shutter : cam.liveShutter), manual: cam.manualExposure,
                  reset: { cam.setManual(exposure: false) }) {
                Slider(value: shutterBinding, in: 0...1)
            }
        case .wb:
            ruler("WB", "\(Int(cam.manualWB ? cam.temperature : cam.liveTemp))K", manual: cam.manualWB,
                  reset: { cam.setManual(wb: false) }) {
                Slider(value: Binding(get: { cam.manualWB ? cam.temperature : max(2500, min(9000, cam.liveTemp)) },
                                      set: { v in
                                          if !cam.manualWB { cam.setManual(wb: true) }
                                          cam.temperature = v
                                          cam.applyManual()
                                      }), in: 2500...9000)
            }
        case .focus:
            ruler("Fokus", String(format: "%.2f", cam.manualFocus ? cam.lensPosition : cam.liveLens), manual: cam.manualFocus,
                  reset: { cam.setManual(focus: false) }) {
                Slider(value: Binding(get: { cam.manualFocus ? cam.lensPosition : cam.liveLens },
                                      set: { v in
                                          if !cam.manualFocus { cam.setManual(focus: true) }
                                          cam.lensPosition = v
                                          cam.applyManual()
                                      }), in: 0...1)
            }
        case .timer:
            HStack {
                Text("Timer").font(.caption).frame(width: 56, alignment: .leading)
                Picker("Timer", selection: $cam.timerSeconds) {
                    Text("Mati").tag(0)
                    Text("3 s").tag(3)
                    Text("10 s").tag(10)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    /// satu penggaris: judul · slider · nilai · tombol A (kembali auto)
    private func ruler<S: View>(_ title: String, _ value: String, manual: Bool, reset: @escaping () -> Void,
                                @ViewBuilder slider: () -> S) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            slider().tint(.yellow)
            Text(value).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                .foregroundStyle(manual ? .yellow : .white)
            Button(action: reset) {
                Text("A").font(.caption.bold())
                    .frame(width: 26, height: 26)
                    .background(manual ? Color.white.opacity(0.2) : Color.yellow, in: Circle())
                    .foregroundStyle(manual ? .white : .black)
            }
        }
    }

    /// slider 0..1 -> shutter skala logaritmik (menggeser = shutter/ISO manual)
    private var shutterBinding: Binding<Double> {
        Binding(
            get: {
                let r = cam.shutterRange
                let s = cam.manualExposure ? cam.shutter : max(cam.liveShutter, r.lowerBound)
                return log(s / r.lowerBound) / log(r.upperBound / r.lowerBound)
            },
            set: { t in
                let r = cam.shutterRange
                if !cam.manualExposure { cam.setManual(exposure: true) }
                cam.shutter = r.lowerBound * pow(r.upperBound / r.lowerBound, t)
                cam.applyManual()
            })
    }

    static func shutterText(_ s: Double) -> String {
        guard s > 0 else { return "-" }
        return s >= 0.5 ? String(format: "%.1fs", s) : "1/\(Int((1 / s).rounded()))"
    }

    // MARK: - status · shutter · mode
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let p = cam.progress { ProgressView(value: p).tint(.yellow) }
            Text(cam.status)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shutterRow: some View {
        HStack {
            Button { if !cam.isRecording { cam.stop() }; showViewer = true } label: {      // v0.16: album ala kamera bawaan (kamera dijeda)
                Group {
                    if let t = cam.lastThumb {
                        Image(uiImage: t).resizable().scaledToFill()
                            .rotationEffect(uiRot).animation(.easeInOut(duration: 0.25), value: level.captureAngle)
                    } else {
                        Image(systemName: "photo").font(.title3).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 54, height: 54)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: cam.shutterPressed) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                    if cam.shootMode == .video {
                        if cam.isRecording {
                            RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(Color.red).frame(width: 62, height: 62)
                        }
                    } else {
                        Circle().fill(shutterColor).frame(width: 64, height: 64)
                    }
                    if cam.isCapturing {
                        ProgressView().tint(.white)
                    } else if cam.shootMode == .night {
                        Image(systemName: "moon.stars.fill").font(.title2).foregroundStyle(.yellow)
                    }
                }
            }
            .disabled(cam.isCapturing)

            Button(action: flipCamera) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(uiRot).animation(.easeInOut(duration: 0.25), value: level.captureAngle)
                    .font(.title2)
                    .frame(width: 54, height: 54)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .foregroundStyle(isFront ? .yellow : .white)
            }
            .disabled(cam.isCapturing || cam.isRecording || !cam.availableLenses.contains(.front))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var shutterColor: Color {
        if cam.isCapturing { return .red }
        switch cam.shootMode {
        case .night: return Color(red: 0.12, green: 0.12, blue: 0.3)
        case .pro: return .white
        case .video: return .red
        case .photo: return cam.photoProcess == .apple ? .white : .yellow
        }
    }

    private var isFront: Bool {
        CameraManager.usesVirtual(cam.mode) ? cam.aiLensLock == .front : cam.lens == .front
    }

    private func flipCamera() {
        if CameraManager.usesVirtual(cam.mode) {
            cam.setAILensLock(cam.aiLensLock == .front ? nil : .front)
        } else {
            cam.setLens(cam.lens == .front ? .wide : .front)
        }
    }

    private var modeRow: some View {
        ZStack {
            HStack(spacing: 26) {
                ForEach(CameraManager.ShootMode.allCases) { s in
                    let on = cam.shootMode == s
                    Button { withAnimation(.easeOut(duration: 0.2)) { cam.setShootMode(s) } } label: {
                        Text(s.rawValue)
                            .font(.footnote.weight(on ? .bold : .semibold))
                            .padding(.horizontal, on ? 12 : 4).padding(.vertical, 5)
                            .background(on ? Color.yellow.opacity(0.9) : Color.clear, in: Capsule())
                            .foregroundStyle(on ? .black : .white)
                    }
                    .disabled(cam.isCapturing || cam.isRecording)
                }
            }
            HStack {
                Spacer()
                Button { withAnimation { showPro.toggle() } } label: {
                    Image(systemName: "slider.horizontal.3")
                        .rotationEffect(uiRot).animation(.easeInOut(duration: 0.25), value: level.captureAngle)
                        .font(.title3)
                        .frame(width: 40, height: 34)
                        .foregroundStyle(showPro || !cam.isAuto ? .yellow : .white)
                }
            }
        }
        .frame(height: 36)
        .padding(.bottom, 8)
    }
}

/// v0.17: panel Bantu (bisa di-scroll, tinggi sedang / penuh)
private struct AssistPanel: View {
    @ObservedObject var cam: CameraManager
    let comp: CompositionAI
    @Binding var peaking: Bool
    @Binding var peakColor: String
    @Binding var zebra: Bool
    @Binding var zebraLevel: Double
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    @Binding var showHistogram: Bool
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if cam.shootMode != .video {
                    Section {
                        Toggle("Susun ulang (saran framing)", isOn: $cam.compAI)
                        Toggle("Simpan versi crop setelah jepret", isOn: $cam.compCrop)
                        if cam.compAI {
                            Button { close(); comp.startScan() } label: { Label("Susun ulang sekarang", systemImage: "crop") }
                        }
                    } header: { Text("AI Komposisi") }
                }
                Section {
                    Toggle("Focus peaking", isOn: $peaking)
                    if peaking {
                        Picker("Warna", selection: $peakColor) {
                            ForEach(ContentView.peakColors, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: { Text("Fokus") } footer: { Text("Tepi yang tajam diberi warna - hanya di layar.") }
                Section {
                    Toggle("Zebra", isOn: $zebra)
                    if zebra {
                        Picker("Level", selection: $zebraLevel) {
                            ForEach([0.70, 0.80, 0.90, 0.95, 1.0], id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: { Text("Eksposur") } footer: { Text("Garis-garis di area yang hampir putih (terbakar).") }
                if cam.shootMode == .video {
                    Section {
                        Picker("Garis bingkai", selection: $cam.frameGuide) {
                            ForEach(FrameGuide.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } header: { Text("Bingkai") }
                }
                Section {
                    Toggle("Grid 3x3", isOn: $showGrid)
                    Toggle("Waterpass", isOn: $showLevel)
                    Toggle("Histogram", isOn: $showHistogram)
                } header: { Text("Layar") }
            }
            .navigationTitle("Bantu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Selesai") { close() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
