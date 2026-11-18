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
    @State private var pipDragStart: CGPoint?
    @AppStorage("videoFullScreen") private var videoFull = true
    private var videoFullActive: Bool { videoFull && cam.shootMode == .video }
    /// v0.40: jendela bidik video mengisi seluruh layar (tanpa bar hitam atas-bawah); sisi kiri-kanan rekaman 16:9
    /// tidak terlihat di preview (layar 19,5:9 lebih ramping dari video)
    @AppStorage("videoFill") private var videoFill = true
    /// v0.40.2: LUT di preview (mati = preview lebih ringan; LUT tetap dibakar ke foto / video bila disetel)
    @AppStorage("previewLUT") private var previewLUT = true
    /// v0.41.3: efek Dynamic Island saat ganti kamera
    @AppStorage("flipFX") private var flipFX = FlipFX.orbit.rawValue
    @State private var fxTick = 0
    @State private var fxFront = true
    /// v0.41.4: tirai blur di preview saat ganti kamera (menutupi jeda, seperti kamera bawaan)
    @State private var flipVeil = false
    private var videoFillActive: Bool { videoFullActive && videoFill && cam.videoKind != .dual }
    /// v0.40.1: isi layar - preview mulai dari ujung atas layar; elemen di atas preview diturunkan sejauh tepi atas
    /// preview 16:9 yang lama supaya tidak menutup Dynamic Island / baris atas (screenshot 17 Nov 16:02)
    private var fillTopInset: CGFloat {
        guard videoFillActive else { return 0 }
        let b = UIScreen.main.bounds
        return max(0, (b.height - b.width * 16 / 9) / 2)
    }
    @State private var lightSavedBrightness: CGFloat = 0.5
    @State private var proControl: ProControl = .ev
    /// v0.40.4: @State berisi objek - bin baru tidak menggambar ulang seluruh layar
    @State private var histo = HistogramState()
    @State private var histoOn = false
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
    /// v0.39: @State (bukan @StateObject) supaya kotak peta yang bergerak 30x/detik tidak menggambar ulang layar
    @State private var zoomNav = ZoomNavigator()
    @StateObject private var comp = CompositionAI()
    @StateObject private var gimbalGuide = GimbalGuide()
    @StateObject private var faceTracker = FaceTracker()
    @State private var touch = TouchClock()
    @State private var pinchBase: Double?
    /// v0.39: roda zoom ala kamera bawaan (tahan tombol zoom lalu geser)
    @State private var dialActive = false
    @State private var dialStart = 1.0
    @State private var dialToken = 0
    @State private var showAssist = false
    @State private var showDrawer = false
    /// v0.28 (UI B): saklar PRO = angka eksposur + histogram + alat bantu di layar
    @AppStorage("proLayer") private var proOn = false

    enum ProControl: String, CaseIterable, Identifiable {
        case ev = "EV", iso = "ISO", shutter = "Shutter", aperture = "Aperture", wb = "WB", focus = "Fokus", timer = "Timer"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .ev: return "plusminus.circle"
            case .iso: return "camera.aperture"
            case .shutter: return "timer"
            case .aperture: return "f.cursive"
            case .wb: return "thermometer.medium"
            case .focus: return "scope"
            case .timer: return "clock"
            }
        }
    }

    var body: some View {
        let _ = BodyCounter.tick()
        ZStack {
            Color.black.ignoresSafeArea()
            if videoFullActive {
                // VIDEO / SINEMA / DUAL: jendela bidik selebar layar, kontrol melayang di atasnya
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 130)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).frame(height: 340)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            VStack(spacing: 6) {
                topBar
                if proOn { proValues }
                if !videoFullActive { preview }
                if videoFullActive { Spacer(minLength: 0) }
                if showsZoom { zoomRow }
                if !videoFullActive { Spacer(minLength: 0) }
                if showPro { proDrawer }
                if !CameraManager.usesVirtual(cam.mode) { lensRow }
                drawerGrabber
                statusLine
                shutterRow
                modeRow
            }
            .padding(.horizontal, 12)
            if cam.idlePaused { idlePauseLayer }
            if cam.screenFlash { Color(red: 1, green: 0.97, blue: 0.92).ignoresSafeArea().allowsHitTesting(false) }
            FlipFXOverlay(trigger: fxTick, toFront: fxFront, style: FlipFX(rawValue: flipFX) ?? .orbit)
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
            r.navigator = zoomNav
            let cq = cam
            VideoAIQueue.shared.cameraBusy = { cq.isRecording || cq.isCapturing || cq.pendingJobs > 0 || cq.countdown > 0 }
            VideoAIQueue.shared.onRunningChange = { cq.refreshIdleTimer() }
            VideoAIQueue.shared.start()
            zoomNav.enabled = navEnabled
            let cm = comp
            level.onRoll = { [weak cm] v in cm?.roll = v }
            HardwareInput.shared.handler = { a, src in handleHardware(a, src) }   // v0.21: gimbal / remote
            HardwareInput.shared.onControllerConnect = { vendor, cat in
                Log.camera.notice("Auto-gimbal: controller tersambung (\(vendor, privacy: .public), \(cat, privacy: .public)), gimbalAuto=\(cam.gimbalAuto, privacy: .public)")
                if cam.gimbalAuto && !cam.gimbalMode { cam.gimbalMode = true }
            }
            HardwareInput.shared.onControllerDisconnect = {
                let still = HardwareInput.shared.hasController
                Log.camera.notice("Auto-gimbal: controller terputus, sisa controller=\(still, privacy: .public)")
                if cam.gimbalAuto && cam.gimbalMode && !still { cam.gimbalMode = false }
            }
            HardwareInput.shared.onZoom = { factor in cam.zoomStep(factor) }
            HardwareInput.shared.gimbalActive = cam.gimbalMode
            let lv = level
            cam.motionLevel = { [weak lv] in lv?.rotationLevel ?? -1 }
            let hs = histo
            r.onHistogram = { [weak hs] bins in hs?.bins = bins }
            r.zebra = zebra
            r.peaking = peaking
            r.zebraLevel = Float(zebraLevel)
            r.peakColor = Self.peakCI(peakColor)
            comp.onAutoZoom = { z in cam.setTotalZoom(cam.totalZoom * z) }
            cam.orientationAngle = { [weak lv] in lv?.angleNow ?? 90 }
            LibraryViewer.latestThumb { t in cam.showLibraryThumb(t) }
            updateComp()
            showHistogram = proOn
            cam.start()
            level.start()
            if luts.selected == nil {
                luts.select(luts.items.first { $0.name.contains("STANDARD") } ?? luts.items.first)
            }
        }
        .onChange(of: luts.filter) { _, newFilter in renderer.lutFilter = previewLUT ? newFilter : nil; cam.captureLUT = luts.current }
        .onChange(of: previewLUT) { _, v in renderer.lutFilter = v ? luts.filter : nil }
        .onChange(of: cam.previewExtraZoom) { _, z in renderer.zoom = z }
        .onChange(of: cam.totalZoom) { _, z in zoomNav.setZoom(z, fovTan1x: cam.fovTan1x) }
        .onChange(of: navEnabled) { _, v in zoomNav.enabled = v }
        .onChange(of: cam.previewFrozen) { _, v in renderer.frozen = v }
        .onChange(of: zebra) { _, v in renderer.zebra = v }
        .onChange(of: peaking) { _, v in renderer.peaking = v }
        .onChange(of: zebraLevel) { _, v in renderer.zebraLevel = Float(v) }
        .onChange(of: peakColor) { _, v in renderer.peakColor = Self.peakCI(v) }
        // v0.40.2: penajaman zoom hanya untuk rekaman (preview tidak ditajamkan - lebih ringan)
        .onChange(of: faceTracker.cropRect) { _, r in cam.faceTrackerCrop = cam.faceTrack ? r : nil }
        .onChange(of: level.steady) { _, v in cam.deviceSteady = v }
        .onChange(of: showHistogram) { _, v in renderer.histogramEnabled = v; if !v { histo.bins = [] } }
        .onReceive(histo.$bins.map { !$0.isEmpty }.removeDuplicates()) { v in if v != histoOn { histoOn = v } }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
            if case .success(let url) = result { luts.importLUT(from: url) }
        }
        .modifier(CompHooks(cam: cam, comp: comp, level: level, update: updateComp, maxZoom: { compMaxZoom }))
        .modifier(PowerHooks(cam: cam, level: level, touch: touch, busy: { showUpscale || showSettings || showViewer || showAssist || showDrawer },
                             histogram: { on in renderer.histogramEnabled = on && showHistogram; if !on { histo.bins = [] } }))
    }

    // MARK: - baris 1: chip cepat
    private var topBar: some View {
        HStack(spacing: 6) {
            topLeft.frame(width: 50, alignment: .leading)
            Spacer(minLength: 0)
            processPill
            Spacer(minLength: 0)
            proToggle.frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 4)
        // v0.41.2: seluruh strip atas menahan sentuhan - ketukan di sela ikon tidak lagi memindah fokus kamera
        // (log 18 Nov: 7 "Fokus di layar" pada y 0,06-0,08 = baris ikon)
        .contentShape(Rectangle())
        .onTapGesture {}
        .padding(.top, 2)
    }

    @ViewBuilder private var topLeft: some View {
        if cam.shootMode == .video {
            torchChip
        } else if cam.flashAvailable || isFront {
            flashChip
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// pil tengah: cara foto / video diproses, isinya mengikuti mode
    @ViewBuilder private var processPill: some View {
        switch cam.shootMode {
        case .photo: photoPill
        case .night: nightPill
        case .portrait: HStack(spacing: 6) { bokehChip; beautyChip }
        case .pro: processChip
        case .video:
            HStack(spacing: 6) {
                if cam.videoKind == .cinematic { bokehChip }
                if cam.videoKind == .normal && isFront { videoBeautyChip }
                videoFormatChip
            }
        }
    }

    /// zoom di luar titik lensa optik -> hasil diproses Super Res / AI
    private var zoomProcessed: Bool {
        guard showsZoom, cam.shootMode != .video else { return false }
        if isFront { return displayZoom > 1.05 }
        return ![0.5, 1.0, Double(CameraManager.teleNative)].contains { abs($0 - displayZoom) < 0.05 }
    }

    private var zoomText: String { cam.zoomMethod.rawValue + (cam.zoomAIEnabled ? " + AI" : "") }

    private var photoPill: some View {
        Menu {
            Section("Proses foto") {
                ForEach(CameraManager.PhotoProcess.allCases) { p in
                    Button { cam.setPhotoProcess(p) } label: { check(p.rawValue, cam.photoProcess == p, detail: p.detail) }
                }
            }
            Toggle("Jumlah frame otomatis (6-15)", isOn: $cam.autoFrames)
            if DeviceCaps.has48MP { Toggle("Fusi detail 48MP", isOn: $cam.fusion48) }
            if showsZoom { zoomMenuItems }
            Button("Pengaturan lain...") { showSettings = true }
        } label: {
            let forced = (cam.livePhoto || cam.flash == .on) && cam.photoProcess != .apple
            let base = cam.photoProcess.rawValue + (forced ? " → Apple" : "") + (framesText.map { " · " + $0 } ?? "")
            chip(zoomProcessed ? zoomText : base,
                 icon: zoomProcessed ? "plus.magnifyingglass" : (cam.photoProcess == .apple ? "apple.logo" : "sparkles"), on: true)
        }
    }

    private var nightPill: some View {
        Menu {
            Text("Jumlah frame dan lama eksposur dipilih otomatis menurut cahaya dan goyangan HP. Di tripod / gimbal, eksposur lebih panjang.")
            Button("Pengaturan lain...") { showSettings = true }
        } label: {
            chip("MALAM" + (framesText.map { " · " + $0 } ?? ""), icon: "moon.stars.fill", on: true)
        }
    }

    /// cara zoom + AI (dipakai bila zoom melewati lensa optik)
    @ViewBuilder private var zoomMenuItems: some View {
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
    }

    private var proToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                proOn.toggle()
                showHistogram = proOn
                if !proOn { showPro = false }
            }
        } label: {
            let lit = proOn || !cam.isAuto
            Text("PRO")
                .font(.caption.weight(.heavy))
                .frame(width: 48, height: 38)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(lit ? Color.yellow.opacity(0.85) : Color.white.opacity(0.14), lineWidth: 1))
                .foregroundStyle(lit ? Color.yellow : Color.white)
                .environment(\.colorScheme, .dark)
        }
    }

    /// PRO nyala: angka eksposur selalu tampil; ketuk = penggaris nilai muncul di atas shutter
    private var proValues: some View {
        HStack(spacing: 5) {
            proValue(.iso, "ISO", "\(Int(cam.manualExposure ? cam.iso : cam.liveISO))")
            proValue(.shutter, "SHUTTER", Self.shutterText(cam.manualExposure ? cam.shutter : cam.liveShutter))
            proValue(.wb, "WB", "\(Int(cam.manualWB ? cam.temperature : cam.liveTemp))K")
            proValue(.ev, "EV", String(format: "%+.1f", cam.evBias))
            proValue(.focus, "FOKUS", String(format: "%.2f", cam.manualFocus ? cam.lensPosition : cam.liveLens))
            if !cam.apertureStops.isEmpty {
                proValue(.aperture, "F", cam.liveAperture > 0 ? String(format: "%.1f", cam.liveAperture) : "-")
            }
        }
    }

    private func proValue(_ c: ProControl, _ title: String, _ value: String) -> some View {
        let on = showPro && proControl == c
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if on { showPro = false } else { proControl = c; showPro = true }
            }
        } label: {
            VStack(spacing: 0) {
                Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white.opacity(0.6))
                Text(value).font(.footnote.monospacedDigit().bold())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(isManual(c) ? Color.yellow : Color.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.yellow.opacity(0.85) : Color.white.opacity(0.14), lineWidth: 1))
            .environment(\.colorScheme, .dark)
        }
    }

    /// PRO nyala: alat bantu di tepi kiri preview
    private var toolStrip: some View {
        VStack(spacing: 8) {
            toolButton("grid", showGrid) { showGrid.toggle() }
            toolButton("level", showLevel) { showLevel.toggle() }
            toolButton("scope", peaking) { peaking.toggle() }
            toolButton("line.diagonal", zebra) { zebra.toggle() }
        }
        .padding(.leading, 8)
    }

    private func toolButton(_ icon: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(on ? Color.yellow.opacity(0.85) : Color.white.opacity(0.14), lineWidth: 1))
                .foregroundStyle(on ? Color.yellow : Color.white)
                .environment(\.colorScheme, .dark)
        }
    }

    /// pegangan laci pengaturan (ketuk atau geser ke atas)
    private var drawerGrabber: some View {
        Button { showDrawer = true } label: {
            Label("pengaturan", systemImage: "chevron.up")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { v in
            if v.translation.height < -10 { showDrawer = true }
        })
        .disabled(cam.isCapturing)
        .sheet(isPresented: $showDrawer) {
            ControlDrawer(cam: cam, luts: luts, peaking: $peaking, peakColor: $peakColor, zebra: $zebra,
                          zebraLevel: $zebraLevel, showGrid: $showGrid, showLevel: $showLevel, isFront: isFront,
                          lutName: luts.selected.map { shortLUT($0.name) } ?? "Tanpa",
                          compScan: { showDrawer = false; comp.startScan() },
                          open: { target in openFromDrawer(target) })
        }
    }

    private func openFromDrawer(_ target: ControlDrawer.Target) {
        showDrawer = false
        if target == .manualWB {
            proOn = true
            showHistogram = true
            proControl = .wb
            showPro = true
            return
        }
        // lembar baru baru bisa dibuka setelah laci selesai menutup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch target {
            case .settings: showSettings = true
            case .importLUT: showImporter = true
            case .upscale: showUpscale = true
            case .manualWB: break
            }
        }
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
                    guard !cam.idlePaused, !cam.isRecording, !cam.isCapturing, cam.pendingJobs == 0, cam.countdown == 0, !busy() else { return }
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
                .onChange(of: cam.gimbalMode) { _, on in HardwareInput.shared.gimbalActive = on; update() }
                .onChange(of: cam.gimbalGuideOn) { _, _ in update() }
                .onChange(of: cam.faceTrack) { _, _ in update() }
                .onChange(of: cam.shootMode) { _, _ in update() }
                .onChange(of: cam.aiLensLock) { _, _ in update() }
                .onChange(of: cam.totalZoom) { _, _ in comp.maxZoom = maxZoom() }
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
        // v0.21: analisis preview dibagi AI Komposisi + panduan gimbal + face tracker
        let useComp = compActive, useG = cam.gimbalMode && cam.gimbalGuideOn, useFT = cam.faceTrack
        if useComp || useG || useFT {
            let c = comp, gg = gimbalGuide, ft = faceTracker
            renderer.onAnalysis = { [weak c, weak gg, weak ft] img in
                if useComp { c?.push(img) }
                if useG { gg?.push(img) }
                if useFT { ft?.push(img) }
            }
        } else {
            renderer.onAnalysis = nil
        }
        if !useComp { comp.close() }
        if !useG { gimbalGuide.reset() }
        if !useFT { faceTracker.reset(); cam.faceTrackerCrop = nil }
    }

    /// v0.21: tombol gimbal / remote / keyboard Bluetooth
    private func handleHardware(_ a: GimbalAction, _ src: String) {
        touch.mark()
        if cam.idlePaused { cam.resumeIdle(); return }
        switch a {
        case .shutter: cam.hardwareShutter(source: src)
        case .zoomIn: cam.zoomStep(1.2)
        case .zoomOut: cam.zoomStep(1 / 1.2)
        case .flip: if !cam.isRecording && !cam.isCapturing { flipCamera() }
        case .pause: cam.togglePause()
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
        Group {
            if text.isEmpty { Image(systemName: icon) } else { Label(text, systemImage: icon) }
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        // v0.41.2: lebih besar (dulu tinggi ~30 pt, meleset ke fokus sentuh di bawahnya)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minWidth: 42, minHeight: 38)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
        .overlay(Capsule().stroke(on ? Color.yellow.opacity(0.85) : Color.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(on ? Color.yellow : Color.white)
        .environment(\.colorScheme, .dark)
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
        case .portrait:
            bokehChip
        case .video:
            switch cam.videoKind {
            case .normal: chip("VIDEO", icon: "video.fill", on: true)
            case .cinematic: chip("SINEMA", icon: "camera.aperture", on: true)
            case .dual: chip("DUAL", icon: "pip.fill", on: true)
            }
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
                    ForEach(OutputMP.available) { r in
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
        var t = n.replacingOccurrences(of: "SonyLook_", with: "").replacingOccurrences(of: "_100", with: "")
        if t.hasPrefix("v"), let i = t.firstIndex(of: "_"), t.distance(from: t.startIndex, to: i) <= 6 {
            t = String(t[t.index(after: i)...])
        }
        return t
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
                    ForEach(OutputMP.available) { r in
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
            Text("Belakang di FOTO: flash kamera (proses Apple). HDR+ / POTRET / PRO: senter menyala selama jepretan. Kamera depan: layar jadi lampu putih. Auto = hanya saat gelap.")
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
            chip(cam.videoKind == .normal
                 ? "\(cam.videoRes.rawValue) · \(rate) · \(cam.videoCodec.short) · \(cam.videoColor.short)"
                 : "\(cam.videoRes.rawValue) · \(rate)", icon: "video", on: true)
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
                check("AI setelah rekam (masuk antrean)", cam.aiAfterRecord)
            }
            Button { showUpscale = true } label: { Label("Buka AI Upscale...", systemImage: "sparkles") }
            Text("AI terlalu berat untuk real-time; diproses setelah rekam (~1-2 s/frame)")
        } label: { chip(cam.aiAfterRecord ? "AI ON" : "AI", icon: "sparkles", on: cam.aiAfterRecord) }
        .disabled(cam.isRecording)
    }

    /// kekuatan blur latar (POTRET & SINEMA)
    private var bokehChip: some View {
        Menu {
            ForEach([(25.0, "Tipis"), (50.0, "Natural"), (75.0, "Kuat"), (100.0, "Maksimal")], id: \.0) { v, name in
                Button { cam.bokehIntensity = v } label: { check("\(name) \(Int(v))%", abs(cam.bokehIntensity - v) < 2.5) }
            }
            Toggle("Kedalaman (seperti iPhone)", isOn: $cam.portraitDepth)
            if cam.portraitDepth && !cam.depthReady {
                Text("Kedalaman hanya untuk kamera belakang (lensa Auto) - di sini memakai cara lama")
            }
            Text("Atur lebih halus: laci pengaturan")
        } label: {
            chip("Bokeh \(Int(cam.bokehIntensity))%" + (cam.portraitDepth && cam.depthReady ? " · 3D" : ""), icon: "camera.aperture", on: true)
        }
    }

    /// percantik wajah (foto)
    /// v0.41: percantik video selfie
    private var videoBeautyChip: some View {
        Menu {
            ForEach(CameraManager.VideoBeautyLevel.allCases) { l in
                Button { cam.videoBeauty = l } label: { check(l.rawValue, cam.videoBeauty == l) }
            }
            Text("Menghaluskan kulit di video kamera depan (langsung terlihat di layar). Hanya SDR - HLG / Log tidak")
        } label: {
            chip(cam.videoBeauty.active ? cam.videoBeauty.rawValue : "", icon: "face.smiling", on: cam.videoBeauty.active)
        }
    }

    private var beautyChip: some View {
        Menu {
            ForEach(CameraManager.BeautyLevel.allCases) { l in
                Button { cam.beautyLevel = l } label: { check(l.rawValue, cam.beautyLevel == l) }
            }
            Text("Menghaluskan kulit di foto HDR+ tanpa zoom")
        } label: {
            chip(cam.beautyLevel.active ? cam.beautyLevel.rawValue : "", icon: "face.smiling", on: cam.beautyLevel.active)
        }
    }

    /// lampu layar untuk video kamera depan
    private var videoLightChip: some View {
        Menu {
            ForEach(CameraManager.VideoLight.allCases) { l in
                Button { cam.videoLight = l } label: { check(l.rawValue, cam.videoLight == l) }
            }
            Text("Lampu layar kamera depan (foto, potret, video): tepi preview jadi putih terang untuk menerangi wajah. Tidak ikut terekam / terfoto.")
        } label: {
            chip(cam.videoLight == .off ? "" : cam.videoLight.rawValue, icon: cam.videoLight == .off ? "sun.max" : "sun.max.fill",
                 on: cam.videoLight != .off)
        }
    }

    private var activeVideoLight: CameraManager.VideoLight {
        isFront || cam.videoKind == .dual ? cam.videoLight : .off
    }

    /// bingkai putih di tepi preview (lubang bersudut bulat di tengah)
    private var videoLightLayer: some View {
        GeometryReader { g in
            let b = g.size.width * activeVideoLight.border
            Path { p in
                p.addRect(CGRect(origin: .zero, size: g.size))
                p.addRoundedRect(in: CGRect(origin: .zero, size: g.size).insetBy(dx: b, dy: b),
                                 cornerSize: CGSize(width: b * 0.6, height: b * 0.6))
            }
            .fill(Color(red: 1, green: 0.97, blue: 0.92), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
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
            if cam.recPaused {
                Image(systemName: "pause.fill").font(.caption2)
            } else {
                Circle().fill(cam.isRecording ? Color.white : Color.red).frame(width: 9, height: 9)
            }
            Text(recordTimeText).font(.system(.callout, design: .monospaced).bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(cam.recPaused ? Color.orange : (cam.isRecording ? Color.red : Color.black.opacity(0.55)), in: Capsule())
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
                if !cam.isRecording && cam.videoKind == .dual && !cam.videoInfo.isEmpty { infoPill(cam.videoInfo, icon: "video") }
                if !cam.zoomQuality.isEmpty && (cam.zoomQuality != "Native" || cam.totalZoom > 1.05) {
                    infoPill(cam.zoomQuality, icon: cam.zoomQuality == "Native" ? "sparkle" : "plus.magnifyingglass",
                             color: cam.zoomQuality == "Native" ? .green : .orange)
                }
                if cam.needND { infoPill("ND", icon: "sun.max.fill", color: .orange) }
                if cam.gimbalMode { infoPill("Gimbal", icon: "gyroscope", color: .green) }
                if cam.faceTrack { infoPill("Face Track", icon: "person.crop.rectangle", color: .cyan) }
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
        MetalPreview(renderer: renderer, onHardwareShutter: { src in
            touch.mark()
            if cam.idlePaused { cam.resumeIdle(); return }
            // gimbal mode: jangan langsung shutter, lewatkan ke volumeEvent untuk deteksi zoom vs shutter
            if cam.gimbalMode {
                let isPrimary = src.contains("primer")
                HardwareInput.shared.volumeEvent(isPrimary: isPrimary)
            } else {
                cam.hardwareShutter(source: src)
            }
        }, onVolumeEvent: { isPrimary, phase in
            Log.camera.notice("Volume: primary=\(isPrimary, privacy: .public) phase=\(phase, privacy: .public)")
        }, fps: cam.thermal >= 3 ? 20 : 30)      // v0.40.1: 20 fps hanya saat kritis (suhu 2 = 17-19 fps, tersendat dibanding kamera bawaan)
            .modifier(PreviewAspect(ratio: videoFillActive ? nil : (cam.shootMode == .video ? 9.0 / 16.0 : 3.0 / 4.0)))
            .clipped()
            .overlay { if flipVeil { Rectangle().fill(.ultraThinMaterial).allowsHitTesting(false).transition(.opacity) } }
            .overlay { ratioMask }
            .overlay { frameGuideOverlay }
            .overlay { if cam.gimbalMode && cam.gimbalGuideOn { GimbalOverlay(guide: gimbalGuide) } }
            .overlay { if cam.faceTrack { FaceTrackOverlay(tracker: faceTracker) } }
            .overlay(alignment: .topTrailing) {
                if showHistogram && histoOn {
                    HistogramBox(s: histo)
                        .padding(.top, (cam.shootMode == .video ? 82 : 48) + (videoFullActive && proOn ? 46 : 0) + fillTopInset).padding(8)
                }
            }
            .overlay(alignment: .leading) {
                if proOn && !(cam.isRecording && cam.recCanFlip && cam.videoKind != .dual) { toolStrip }
            }
            .overlay { if showGrid { GridOverlay().allowsHitTesting(false) } }
            .overlay { if showLevel { LevelOverlay(level: level) } }
            .overlay(alignment: .topTrailing) {
                ZoomNavigatorView(nav: zoomNav)
                    .padding(.top, (cam.shootMode == .video ? 82 : 48) + (showHistogram && histoOn ? 64 : 0)
                             + (videoFullActive && proOn ? 46 : 0) + fillTopInset).padding(8)
            }
            .overlay { countdownLayer }
            .overlay { focusLayer }
            .overlay { if compActive && !cam.isCapturing { CompositionOverlay(comp: comp) } }
            .overlay(alignment: .trailing) { if cam.gimbalMode && showsZoom { gimbalZoomStrip } }
            .overlay { if activeVideoLight != .off { videoLightLayer } }
            .overlay { if cam.videoKind == .dual { dualPipLayer } }
            .overlay(alignment: .leading) {
                // VIDEO / SINEMA: pindah kamera belakang <-> depan di tengah rekaman (tombol flip jadi jeda)
                if cam.isRecording && cam.recCanFlip && cam.videoKind != .dual {
                    Button(action: flipCamera) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title3)
                            .frame(width: 46, height: 46)
                            .background(.black.opacity(0.45), in: Circle())
                            .foregroundStyle(isFront ? .yellow : .white)
                    }
                    .padding(.leading, 10)
                }
            }
            .onChange(of: activeVideoLight) { old, new in
                if old == .off { lightSavedBrightness = UIScreen.main.brightness }
                UIScreen.main.brightness = new == .off ? lightSavedBrightness : max(lightSavedBrightness, new.brightness)
            }
            .overlay(alignment: .top) {
                if cam.shootMode == .video { videoInfoRow.padding(.top, (videoFullActive ? (proOn ? 86 : 40) : 0) + fillTopInset) } else { infoRow }
            }
    }

    /// v0.22.1: slider zoom vertikal ala DJI Mimo (T di atas, W di bawah) + tombol flip kamera
    private var gimbalZoomStrip: some View {
        VStack(spacing: 10) {
            Text("T").font(.caption2.bold()).foregroundStyle(.white.opacity(0.7))
            GimbalVerticalSlider(value: zoomBinding)
                .frame(width: 36, height: 180)
            Text("W").font(.caption2.bold()).foregroundStyle(.white.opacity(0.7))
            Button(action: flipCamera) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body.bold())
                    .frame(width: 40, height: 40)
                    .background(isFront ? Color.yellow.opacity(0.8) : Color.white.opacity(0.2), in: Circle())
                    .foregroundStyle(isFront ? .black : .white)
            }
            .disabled(cam.isCapturing)
        }
        .padding(.trailing, 6).padding(.vertical, 40)
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
            if cam.focusRange != .auto {
                Button { cam.focusRange = .auto } label: {
                    infoPill("Fokus " + cam.focusRange.rawValue.lowercased(), icon: "scope", color: .yellow)
                }
            }
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
        if cam.videoKind == .dual { return true }
        return CameraManager.usesVirtual(cam.mode)       // v0.38.1: kamera depan juga (1-4x)
    }

    /// DUAL: area kotak kecil di preview - ketuk = tukar besar/kecil, seret = pindahkan
    private var dualPipLayer: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomTrailing) {
                Color.clear.contentShape(Rectangle())
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.bold())
                    .padding(6)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(cam.dualSwapped ? .yellow : .white)
                    .padding(5)
            }
            .frame(width: g.size.width * DualCam.pipScale, height: g.size.height * DualCam.pipScale)
            .position(x: cam.dualPip.x * g.size.width, y: cam.dualPip.y * g.size.height)
            .onTapGesture { cam.swapDual() }
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { v in
                    let s = pipDragStart ?? cam.dualPip
                    if pipDragStart == nil { pipDragStart = s }
                    cam.setDualPip(CGPoint(x: s.x + v.translation.width / g.size.width,
                                           y: s.y + v.translation.height / g.size.height))
                }
                .onEnded { _ in pipDragStart = nil })
        }
    }

    private var minZoom: Double {
        if cam.videoKind == .dual { return cam.availableLenses.contains(.ultraWide) ? 0.5 : 1 }
        if frontZoomUI { return 0.5 }
        switch cam.aiLensLock {
        case .tele?: return cam.autoTele && !cam.isRecording ? Double(cam.minAutoZoom) : 5
        case .ultraWide?: return 0.5
        case nil: return Double(cam.minAutoZoom)
        default: return 1
        }
    }
    private var maxZoom: Double {
        if cam.videoKind == .dual { return 15 }
        if frontZoomUI { return Self.frontDisplay(Double(cam.maxTotalZoom)) }
        // v0.38.4: video dibatasi zoom yang benar-benar terekam (hardware), bukan crop preview
        if cam.shootMode == .video && !cam.nativeZoomPoints.isEmpty { return min(Double(cam.maxTotalZoom), Double(cam.videoMaxZoom)) }
        return Double(cam.maxTotalZoom)
    }

    /// v0.41.4: skala zoom tampil kamera depan. 0.5x = sensor penuh (zoom device 1), 1x = bingkai selfie kamera bawaan
    /// (device 1.3, bawaan saat dibuka / ganti kamera), 2x = device 2.6. Di bawah 1x linear 0.5 -> 1 = device 1 -> 1.3.
    private var frontZoomUI: Bool { isFront && cam.videoKind != .dual && CameraManager.usesVirtual(cam.mode) }
    private static func frontDisplay(_ d: Double) -> Double {
        let k = Double(CameraManager.frontDefaultZoom)
        return d <= k ? 0.5 + (d - 1) / (k - 1) * 0.5 : d / k
    }
    private static func frontDevice(_ z: Double) -> Double {
        let k = Double(CameraManager.frontDefaultZoom)
        return z <= 1 ? 1 + (max(z, 0.5) - 0.5) * 2 * (k - 1) : z * k
    }

    private var displayZoom: Double { frontZoomUI ? Self.frontDisplay(Double(cam.totalZoom)) : Double(cam.totalZoom) }

    private func setDisplayZoom(_ z: Double, immediate: Bool = false) {
        cam.setTotalZoom(CGFloat(frontZoomUI ? Self.frontDevice(z) : z), immediate: immediate)
    }

    /// v0.39: peta zoom - kamera belakang, bukan DUAL
    private var navEnabled: Bool { showsZoom && !isFront && cam.videoKind != .dual }

    /// slider 0..1 -> zoom min..max skala logaritmik
    private var zoomBinding: Binding<Double> {
        Binding(
            get: { log(displayZoom / minZoom) / log(max(maxZoom / minZoom, 1.01)) },
            set: { t in setDisplayZoom(minZoom * pow(max(maxZoom / minZoom, 1.01), t), immediate: true) })
    }

    private var zoomPresets: [Double] {
        // v0.41.4: kamera depan - 0.5x = sensor penuh, 1x = bingkai selfie kamera bawaan (bawaan), 2x = crop
        if frontZoomUI {
            return [0.5, 1, 2].filter { $0 <= maxZoom + 0.01 }
        }
        if cam.shootMode == .video && !cam.nativeZoomPoints.isEmpty {
            // video: titik native (lensa + crop sensor 48 MP) + 10x
            var p = cam.nativeZoomPoints.map { Double($0) }
            // v0.38.4: + 25x (batas kamera bawaan) dan 40x (crop digital besar, buram) bila hardware mengizinkan
            for z in [10.0, 25, 40] where !p.contains(where: { abs($0 - z) < 0.5 }) { p.append(z) }
            return p.sorted().filter { $0 >= minZoom - 0.01 && $0 <= maxZoom + 0.01 }
        }
        // v0.20: titik tele mengikuti HP (16 Pro Max 5x/10x, 17/18 Pro Max 4x/8x)
        let t = Double(CameraManager.teleNative)
        return [0.5, 1, 2, t, 2 * t, 25, 50, 75].filter { $0 >= minZoom - 0.01 && $0 <= maxZoom + 0.01 }
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(zoomPresets, id: \.self) { z in
                            let on = abs(displayZoom - z) < 0.05
                            Button { if !dialActive { setDisplayZoom(z) } } label: {
                                Text(zoomLabel(z)).fixedSize()
                                    .rotationEffect(uiRot).animation(.easeInOut(duration: 0.25), value: level.captureAngle)
                                    .font(.caption.bold())
                                    .frame(minWidth: 38, minHeight: 28)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .overlay(Capsule().stroke(on ? Color.yellow.opacity(0.85) : Color.white.opacity(0.14), lineWidth: 1))
                                    .foregroundStyle(on ? Color.yellow : Color.white)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .environment(\.colorScheme, .dark)
                .opacity(dialActive ? 0 : 1)
                .overlay {
                    if dialActive {
                        ZoomDial(zoom: displayZoom, minZ: minZoom, maxZ: maxZoom, marks: zoomPresets)
                            .transition(.opacity)
                    }
                }
                // v0.39: tahan tombol zoom 0,3 s lalu geser kiri/kanan = roda zoom (FOTO & VIDEO), seperti kamera bawaan
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.3)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { v in
                            guard case .second(true, let drag) = v, !cam.isCapturing else { return }
                            if !dialActive {
                                dialStart = displayZoom
                                dialToken += 1
                                withAnimation(.easeOut(duration: 0.15)) { dialActive = true }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            let dx = Double(drag?.translation.width ?? 0)
                            setDisplayZoom(min(maxZoom, max(minZoom, dialStart * pow(2, -dx / ZoomDial.ptsPerStop))), immediate: true)
                        }
                        .onEnded { _ in
                            dialToken += 1
                            let t = dialToken
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                if dialToken == t { withAnimation(.easeIn(duration: 0.2)) { dialActive = false } }
                            }
                        })
                if cam.videoKind != .dual && (cam.autoLensAvailable || cam.shootMode != .video) {
                    zoomMenu
                } else {
                    Text(String(format: "%.1fx", displayZoom)).fixedSize()
                        .font(.callout.monospacedDigit().bold()).foregroundStyle(.yellow)
                }
            }
            // v0.39: slider tetap di lapisan PRO; di luar itu roda zoom (tahan tombol zoom lalu geser)
            if proOn { Slider(value: zoomBinding, in: 0...1).tint(.yellow) }
            if cam.videoKind == .dual { dualLensRow }
        }
    }

    /// kunci lensa + cara zoom / AI
    private var zoomMenu: some View {
        Menu {
            if cam.autoLensAvailable {
                Section("Lensa") {
                    ForEach(lockOptions, id: \.self) { l in
                        Button { cam.setAILensLock(l) } label: { check(lockLabel(l), cam.aiLensLock == l) }
                            .disabled(cam.isCapturing || cam.isRecording)
                    }
                }
            }
            if cam.shootMode != .video { zoomMenuItems }
        } label: {
            let locked = cam.aiLensLock != nil && cam.aiLensLock != .front && !cam.autoTele
            let lit = locked || (cam.shootMode != .video && cam.zoomAIEnabled)
            HStack(spacing: 4) {
                if locked { Image(systemName: "lock.fill") }
                if cam.shootMode != .video { Text(zoomText) } else if !locked { Image(systemName: "lock.open") }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.bold())
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(lit ? Color.yellow.opacity(0.85) : Color.white.opacity(0.14), lineWidth: 1))
            .foregroundStyle(lit ? Color.yellow : Color.white)
            .contentShape(Capsule())
            .environment(\.colorScheme, .dark)
        }
    }

    /// DUAL: pilih lensa belakang (boleh saat merekam)
    private var dualLensRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.metering.center.weighted").font(.caption2).foregroundStyle(.white.opacity(0.7))
            ForEach([CameraManager.Lens.ultraWide, .wide, .tele].filter { cam.availableLenses.contains($0) }, id: \.self) { l in
                let on = cam.dualLens == l
                Button(l.displayName) {
                    setDisplayZoom(l == .ultraWide ? 0.5 : (l == .tele ? Double(CameraManager.teleNative) : 1))
                }
                .font(.caption2.bold())
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                .foregroundStyle(on ? .black : .white)
            }
            Spacer(minLength: 0)
            Text("lensa belakang").font(.caption2).foregroundStyle(.white.opacity(0.6))
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
        case .tele?: return "Tele " + CameraManager.lensTitle(.tele)
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
                            setDisplayZoom(min(maxZoom, max(minZoom, (pinchBase ?? displayZoom) * Double(v.magnification))), immediate: true)
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
        var p = CGPoint(x: loc.x / size.width, y: loc.y / size.height)
        if videoFillActive {
            // v0.40: preview isi layar = gambar 9:16 dipotong; titik layar -> titik gambar
            let va = size.width / size.height, ia: CGFloat = 9.0 / 16.0
            if va < ia { p.x = 0.5 + (p.x - 0.5) * va / ia } else { p.y = 0.5 + (p.y - 0.5) * ia / va }
        }
        cam.focus(atViewPoint: p, lock: lock)
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
                        if l == .front { Image(systemName: "person.crop.circle") } else { Text(CameraManager.lensTitle(l)) }
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
        proRuler
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.6), lineWidth: 1))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }

    private func isManual(_ c: ProControl) -> Bool {
        switch c {
        case .ev: return cam.evBias != 0
        case .iso, .shutter: return cam.manualExposure
        case .aperture: return cam.aperture > 0
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
        case .aperture:
            HStack(spacing: 8) {
                Text("Aperture").font(.caption).frame(width: 56, alignment: .leading)
                Picker("Aperture", selection: $cam.aperture) {
                    Text("A").tag(Float(0))
                    ForEach(cam.apertureStops, id: \.self) { f in Text(String(format: "f/%.1f", f)).tag(f) }
                }
                .pickerStyle(.segmented)
                Text(cam.liveAperture > 0 ? String(format: "f/%.1f", cam.liveAperture) : "-")
                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                    .foregroundStyle(cam.aperture > 0 ? .yellow : .white)
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
            VideoAIQueueLine(q: VideoAIQueue.shared)      // v0.40
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
                // v0.38: jumlah foto yang masih diproses di latar
                .overlay(alignment: .topTrailing) {
                    if cam.pendingJobs > 0 {
                        HStack(spacing: 3) {
                            ProgressView().controlSize(.mini).tint(.black)
                            Text("\(cam.pendingJobs)").font(.caption2.bold().monospacedDigit())
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.yellow, in: Capsule())
                        .foregroundStyle(.black)
                        .offset(x: 12, y: -6)
                    }
                }
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

            Group {
                if cam.isRecording {
                    // v0.21: saat merekam tombol ini = jeda / lanjut
                    Button { cam.togglePause() } label: {
                        Image(systemName: cam.recPaused ? "record.circle" : "pause.fill")
                            .font(.title2)
                            .frame(width: 54, height: 54)
                            .background(cam.recPaused ? Color.orange.opacity(0.35) : Color.white.opacity(0.12), in: Circle())
                            .foregroundStyle(cam.recPaused ? .orange : .white)
                    }
                } else {
                    Button(action: flipCamera) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(uiRot).animation(.easeInOut(duration: 0.25), value: level.captureAngle)
                            .font(.title2)
                            .frame(width: 54, height: 54)
                            .background(Color.white.opacity(0.12), in: Circle())
                            .foregroundStyle(isFront ? .yellow : .white)
                    }
                    .disabled(cam.isCapturing || !cam.availableLenses.contains(.front))
                }
            }
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
        case .portrait: return Color(red: 1.0, green: 0.85, blue: 0.4)
        }
    }

    private var isFront: Bool {
        if cam.videoKind == .dual { return cam.dualSwapped }
        return CameraManager.usesVirtual(cam.mode) ? cam.aiLensLock == .front : cam.lens == .front
    }

    private func flipCamera() {
        fxFront = !isFront
        fxTick += 1
        withAnimation(.easeOut(duration: 0.12)) { flipVeil = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { withAnimation(.easeIn(duration: 0.3)) { flipVeil = false } }
        if cam.videoKind == .dual {
            cam.swapDual()
        } else if cam.isRecording {
            cam.flipWhileRecording()
        } else if CameraManager.usesVirtual(cam.mode) {
            cam.setAILensLock(cam.aiLensLock == .front ? nil : .front)
        } else {
            cam.setLens(cam.lens == .front ? .wide : .front)
        }
    }

    private struct ModeItem: Identifiable {
        let id: String
        let mode: CameraManager.ShootMode
        var kind: CameraManager.VideoKind = .normal
    }

    private var modeItems: [ModeItem] {
        var items = [ModeItem(id: "MALAM", mode: .night), ModeItem(id: "FOTO", mode: .photo),
                     ModeItem(id: "POTRET", mode: .portrait), ModeItem(id: "VIDEO", mode: .video),
                     ModeItem(id: "SINEMA", mode: .video, kind: .cinematic)]
        if cam.dualSupported { items.append(ModeItem(id: "DUAL", mode: .video, kind: .dual)) }
        items.append(ModeItem(id: "RAW", mode: .pro))
        return items
    }

    private var currentModeID: String {
        modeItems.first { $0.mode == cam.shootMode && ($0.mode != .video || $0.kind == cam.videoKind) }?.id ?? "FOTO"
    }

    /// baris mode bisa digeser (seperti kamera bawaan): mode aktif selalu ditarik ke tengah
    private var modeRow: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(modeItems) { item in
                            let on = item.id == currentModeID
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if item.mode == .video { cam.setVideoKind(item.kind) } else { cam.setShootMode(item.mode) }
                                }
                            } label: {
                                Text(item.id)
                                    .font(.footnote.weight(on ? .bold : .semibold))
                                    .padding(.horizontal, on ? 12 : 6).padding(.vertical, 5)
                                    .background(on ? Color.yellow.opacity(0.9) : Color.clear, in: Capsule())
                                    .foregroundStyle(on ? .black : .white)
                            }
                            .disabled(cam.isCapturing || cam.isRecording)
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 120)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .onAppear { proxy.scrollTo(currentModeID, anchor: .center) }
                .onChange(of: currentModeID) { _, id in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
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
    @AppStorage("videoFullScreen") private var videoFull = true
    @AppStorage("videoFill") private var videoFill = true
    @AppStorage("previewLUT") private var previewLUT = true

    var body: some View {
        NavigationStack {
            Form {
                // urutan: yang paling sering diatur untuk mode ini di atas, tampilan layar, lalu gimbal
                let photo = cam.shootMode != .video
                let bokeh = cam.shootMode == .portrait || (cam.shootMode == .video && cam.videoKind == .cinematic)
                if photo || bokeh {
                    Section {
                        if photo {
                            Picker("Percantik wajah", selection: $cam.beautyLevel) {
                                ForEach(CameraManager.BeautyLevel.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                        if bokeh {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("Kedalaman bokeh")
                                    Spacer()
                                    Text("\(Int(cam.bokehIntensity))%").foregroundStyle(.secondary)
                                }
                                Slider(value: $cam.bokehIntensity, in: 10...100, step: 5)
                            }
                        }
                    } header: { Text("Wajah & Bokeh") } footer: {
                        Text(bokeh ? "Bokeh: 10% tipis, 50% natural, 100% kuat. Percantik menghaluskan kulit di foto HDR+ tanpa zoom."
                                   : "Percantik menghaluskan kulit di foto HDR+ tanpa zoom. Standard = natural, Strong = lebih mulus.")
                    }
                }
                if photo {
                    Section {
                        Toggle("Susun ulang (saran framing)", isOn: $cam.compAI)
                        Toggle("Simpan versi crop setelah jepret", isOn: $cam.compCrop)
                        if cam.compAI {
                            Button { close(); comp.startScan() } label: { Label("Susun ulang sekarang", systemImage: "crop") }
                        }
                    } header: { Text("AI Komposisi") }
                } else {
                    Section {
                        Toggle("Jendela bidik layar penuh", isOn: $videoFull)
                        if videoFull {
                            Toggle("Isi layar (tanpa bar hitam, tepi kiri-kanan terpotong di layar saja)", isOn: $videoFill)
                        }
                        Toggle("Tetap tele saat zoom >= \(Int(CameraManager.teleNative))x (walau redup)", isOn: $cam.videoTelePriority)
                        Toggle("LUT di preview (mati = lebih ringan)", isOn: $previewLUT)
                        Toggle("Face Tracking Digital", isOn: $cam.faceTrack)
                        Picker("Garis bingkai", selection: $cam.frameGuide) {
                            ForEach(FrameGuide.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } header: { Text("Video") } footer: {
                        Text("Face Tracking: frame di-crop dan digeser halus mengikuti wajah (sumber 4K, hasil 1080p).")
                    }
                }
                Section {
                    Toggle("Grid 3x3", isOn: $showGrid)
                    Toggle("Waterpass", isOn: $showLevel)
                    Toggle("Histogram", isOn: $showHistogram)
                    Toggle("Focus peaking", isOn: $peaking)
                    if peaking {
                        Picker("Warna peaking", selection: $peakColor) {
                            ForEach(ContentView.peakColors, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Zebra", isOn: $zebra)
                    if zebra {
                        Picker("Level zebra", selection: $zebraLevel) {
                            ForEach([0.70, 0.80, 0.90, 0.95, 1.0], id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: { Text("Tampilan layar") } footer: {
                    Text("Peaking mewarnai tepi yang tajam, zebra menandai area hampir putih. Hanya di layar.")
                }
                Section {
                    Toggle("Mode Gimbal", isOn: $cam.gimbalMode)
                    if cam.gimbalMode {
                        Toggle("Panduan tracking (kotak tengah)", isOn: $cam.gimbalGuideOn)
                    }
                    Toggle("Auto-deteksi gimbal", isOn: $cam.gimbalAuto)
                } header: { Text("Gimbal (DJI Osmo Mobile)") } footer: {
                    Text("Tombol rekam gimbal: 1x mulai/stop, 2x cepat saat merekam = jeda/lanjut. Stabilisasi Action/Cinematic diganti Standard. Auto-deteksi menyalakan mode gimbal saat gimbal tersambung lewat Bluetooth.")
                }
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


/// v0.40: rasio preview; nil = mengisi ruang yang ada (video isi layar)
private struct PreviewAspect: ViewModifier {
    let ratio: CGFloat?
    func body(content: Content) -> some View {
        if let ratio { content.aspectRatio(ratio, contentMode: .fit) } else { content }
    }
}
