import SwiftUI

/// v0.28: laci pengaturan (UI B). Ubin besar; bagian teratas mengikuti mode aktif.
struct ControlDrawer: View {
    enum Target { case settings, importLUT, upscale, manualWB }

    @ObservedObject var cam: CameraManager
    @ObservedObject var luts: LUTLibrary
    @ObservedObject private var mics = AudioInputs.shared
    @Binding var peaking: Bool
    @Binding var peakColor: String
    @Binding var zebra: Bool
    @Binding var zebraLevel: Double
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    let isFront: Bool
    let lutName: String
    let compScan: () -> Void
    let open: (Target) -> Void
    @AppStorage("videoFullScreen") private var videoFull = true
    @AppStorage("flipFX") private var flipFX = FlipFX.orbit.rawValue

    private var isVideo: Bool { cam.shootMode == .video }
    private var hasBokeh: Bool { cam.shootMode == .portrait || (isVideo && cam.videoKind == .cinematic) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group(modeTitle) {
                    if hasBokeh { bokehSlider }
                    LazyVGrid(columns: columns, spacing: 8) {
                        if isVideo { videoTiles } else { photoTiles }
                    }
                }
                group("Hasil & warna") {
                    LazyVGrid(columns: columns, spacing: 8) {
                        if isVideo { videoResultTiles } else { photoResultTiles }
                        colorTiles
                    }
                }
                group("Tampilan") {
                    LazyVGrid(columns: columns, spacing: 8) { viewTiles }
                }
                group("Lainnya") {
                    LazyVGrid(columns: columns, spacing: 8) { otherTiles }
                }
            }
            .padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 24)
        }
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(white: 0.09))
    }

    private var modeTitle: String {
        switch cam.shootMode {
        case .night: return "Malam"
        case .photo: return "Foto"
        case .portrait: return "Potret"
        case .pro: return "RAW"
        case .video:
            switch cam.videoKind {
            case .normal: return "Video"
            case .cinematic: return "Sinema"
            case .dual: return "Dual"
            }
        }
    }

    // MARK: - bagian
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            content()
        }
    }

    private var bokehSlider: some View {
        HStack(spacing: 10) {
            Text("Bokeh").font(.footnote.weight(.semibold)).foregroundStyle(.white)
            Slider(value: $cam.bokehIntensity, in: 10...100, step: 5).tint(.yellow)
            Text("\(Int(cam.bokehIntensity))%")
                .font(.footnote.monospacedDigit().bold()).foregroundStyle(.yellow)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - ubin khusus mode
    @ViewBuilder private var photoTiles: some View {
        if cam.shootMode == .photo || cam.shootMode == .portrait {
            menuTile(cam.beautyLevel.rawValue, "Percantik", on: cam.beautyLevel.active) {
                ForEach(CameraManager.BeautyLevel.allCases) { l in
                    pick(l.rawValue, cam.beautyLevel == l) { cam.beautyLevel = l }
                }
            }
        }
        if cam.flashAvailable || isFront {
            menuTile(cam.flash.rawValue, "Flash", on: cam.flash != .off) {
                ForEach(CameraManager.FlashSetting.allCases) { f in
                    pick(f.rawValue, cam.flash == f) { cam.flash = f }
                }
            }
        }
        timerTile
        focusRangeTile
        menuTile(cam.aspect.rawValue, "Rasio", on: cam.aspect != .r43) {
            ForEach(AspectRatio.allCases) { a in
                pick(a.rawValue, cam.aspect == a) { cam.aspect = a }
            }
            Text("Hanya HEIF/JPEG; RAW tetap 4:3")
        }
        if cam.shootMode == .photo && cam.liveAvailable {
            toggleTile(cam.livePhoto ? "livephoto" : "livephoto.slash", "Live", cam.livePhoto) {
                cam.setLivePhoto(!cam.livePhoto)
            }
        }
        toggleTile("crop", "Komposisi AI", cam.compAI) { cam.compAI.toggle() }
        if cam.compAI {
            toggleTile("viewfinder", "Susun ulang", false) { compScan() }
            toggleTile("crop.rotate", "Simpan crop", cam.compCrop) { cam.compCrop.toggle() }
        }
    }

    @ViewBuilder private var videoTiles: some View {
        // v0.42.3: pilih mikrofon (USB-C / kabel / Bluetooth)
        menuTile(micShort, "Mikrofon", on: !mics.preferred.isEmpty) {
            pick("Otomatis (yang terakhir dicolok)", mics.preferred.isEmpty) { mics.preferred = "" }
            ForEach(mics.items) { m in
                pick(m.label, mics.preferred == m.id) { mics.preferred = m.id }
            }
            Text("Dipakai: \(mics.current)")
            Text("Bluetooth (DJI Mic / AirPods) memakai mode telepon iOS: suara 16 kHz. Untuk kualitas penuh pakai penerima USB-C / kabel.")
        }
        .disabled(cam.isRecording)
        if cam.videoKind == .normal && isFront {
            menuTile(cam.videoBeauty.rawValue, "Percantik", on: cam.videoBeauty.active) {
                ForEach(CameraManager.VideoBeautyLevel.allCases) { l in
                    pick(l.rawValue, cam.videoBeauty == l) { cam.videoBeauty = l }
                }
                Text("Video kamera depan, hanya SDR")
            }
        }
        menuTile(cam.videoStab.rawValue, "Stabilisasi") {
            ForEach(VideoStab.allCases) { st in
                pick(st.rawValue, cam.videoStab == st) { cam.videoStab = st }
            }
        }
        .disabled(cam.isRecording)
        if cam.videoKind == .normal {
            menuTile(cam.timelapse > 1 ? "\(cam.timelapse)x" : "Mati", "Time-lapse", on: cam.timelapse > 1) {
                pick("Mati", cam.timelapse <= 1) { cam.timelapse = 1 }
                ForEach([5, 10, 30, 60, 120], id: \.self) { k in
                    pick("\(k)x (diputar 30 fps)", cam.timelapse == k) { cam.timelapse = k }
                }
            }
            .disabled(cam.isRecording)
        }
        toggleTile("timer", "Shutter 180°", cam.shutter180) { cam.shutter180.toggle() }
        if cam.videoKind != .dual {
            toggleTile("person.crop.rectangle", "Face track", cam.faceTrack) { cam.faceTrack.toggle() }
        }
        menuTile(cam.frameGuide.rawValue, "Garis bingkai", on: cam.frameGuide != .off) {
            ForEach(FrameGuide.allCases) { g in
                pick(g.rawValue, cam.frameGuide == g) { cam.frameGuide = g }
            }
        }
        toggleTile("arrow.up.left.and.arrow.down.right", "Layar penuh", videoFull) { videoFull.toggle() }
        timerTile
        focusRangeTile
        toggleTile("sparkles", "AI usai rekam", cam.aiAfterRecord) { cam.aiAfterRecord.toggle() }
        toggleTile("wand.and.stars", "AI Upscale", false) { open(.upscale) }
            .disabled(cam.isRecording)
    }

    private var focusRangeTile: some View {
        menuTile(cam.focusRange.rawValue, "Jarak fokus", on: cam.focusRange != .auto) {
            ForEach(CameraManager.FocusRange.allCases) { r in
                pick(r.rawValue, cam.focusRange == r) { cam.focusRange = r }
            }
            Text("Jauh: autofokus mengabaikan benda dekat (daun, kabel di depan). Dekat: sebaliknya.")
        }
    }

    private var timerTile: some View {
        menuTile(cam.timerSeconds > 0 ? "\(cam.timerSeconds) s" : "Mati", "Timer", on: cam.timerSeconds > 0) {
            pick("Mati", cam.timerSeconds == 0) { cam.timerSeconds = 0 }
            pick("3 detik", cam.timerSeconds == 3) { cam.timerSeconds = 3 }
            pick("10 detik", cam.timerSeconds == 10) { cam.timerSeconds = 10 }
        }
    }

    // MARK: - hasil & warna
    @ViewBuilder private var photoResultTiles: some View {
        if SettingsSheet.showsResolution(cam) {
            menuTile(cam.outputMP.label, "Resolusi") {
                ForEach(OutputMP.available) { r in
                    pick(r.label, cam.outputMP == r) { cam.outputMP = r }
                }
            }
        }
        if cam.mode == .hdrplus {
            menuTile(cam.outputFormat.rawValue, "Format") {
                ForEach(PhotoFormat.allCases) { f in
                    pick(f.rawValue, cam.outputFormat == f) { cam.outputFormat = f }
                }
            }
            toggleTile("square.stack.3d.up", "Frame DNG", cam.saveFrames) { cam.saveFrames.toggle() }
        }
        menuTile(cam.zoomMethod.rawValue, "Cara zoom") {
            ForEach(CameraManager.ZoomMethod.allCases) { z in
                pick(z.rawValue, cam.zoomMethod == z) { cam.zoomMethod = z }
            }
            Text("Dipakai saat zoom melewati lensa optik")
        }
        menuTile(cam.zoomAIEnabled ? cam.srModel.rawValue : "Mati", "AI zoom", on: cam.zoomAIEnabled) {
            pick("Mati", !cam.zoomAIEnabled) { cam.zoomAIEnabled = false }
            ForEach(SRModel.allCases) { m in
                pick("Model \(m.rawValue)", cam.zoomAIEnabled && cam.srModel == m) {
                    cam.zoomAIEnabled = true
                    cam.srModel = m
                }
            }
            Toggle("Fokus tulisan (OCR)", isOn: $cam.textFocus)
        }
        menuTile(cam.colorStyle.rawValue, "Gaya warna", on: cam.colorStyle != .natural) {
            ForEach(ColorStyle.allCases) { st in
                pick(st.rawValue, cam.colorStyle == st) { cam.colorStyle = st }
            }
            Text("Untuk HDR+, MALAM, Super Res, AI Zoom (bukan proses Apple)")
        }
    }

    @ViewBuilder private var videoResultTiles: some View {
        menuTile(cam.videoCodec.short, "Codec") {
            ForEach(VideoCodec.allCases) { c in
                pick(c.rawValue, cam.videoCodec == c) { cam.videoCodec = c }
            }
            Text("ProRes 4K ~5-6 GB/menit")
        }
        .disabled(cam.isRecording)
        menuTile(cam.videoColor.short, "Warna") {
            ForEach(VideoColor.allCases) { c in
                pick(c.rawValue, cam.videoColor == c) { cam.videoColor = c }
            }
            Text("Log: preview otomatis dikonversi ke Rec.709")
        }
        .disabled(cam.isRecording)
    }

    @ViewBuilder private var colorTiles: some View {
        menuTile(lutName, "LUT", on: luts.selected != nil) {
            pick("Tanpa LUT", luts.selected == nil) { luts.select(nil) }
            ForEach(luts.items) { item in
                pick(item.name, luts.selected?.id == item.id) { luts.select(item) }
            }
            Divider()
            if isVideo {
                Toggle("Bakar LUT ke video (keluaran Rec.709)", isOn: $cam.bakeLUTVideo)
            } else {
                Toggle("Bakar LUT ke foto", isOn: $cam.bakeLUT)
            }
            Button("Import .cube...") { open(.importLUT) }
        }
        menuTile(wbText, "White balance", on: cam.manualWB || cam.wbPreset != .auto) {
            ForEach(CameraManager.WBPreset.allCases) { p in
                pick(p.rawValue + (p.kelvin.map { " \(Int($0))K" } ?? ""), !cam.manualWB && cam.wbPreset == p) {
                    cam.setWBPreset(p)
                }
            }
            pick("Manual (Kelvin)...", cam.manualWB) { open(.manualWB) }
        }
    }

    private var wbText: String {
        cam.manualWB ? "\(Int(cam.temperature))K" : (cam.wbPreset == .auto ? "AWB" : cam.wbPreset.rawValue)
    }

    // MARK: - tampilan
    @ViewBuilder private var viewTiles: some View {
        toggleTile("grid", "Grid", showGrid) { showGrid.toggle() }
        menuTile(flipFX, "Efek ganti kamera", on: flipFX != FlipFX.off.rawValue) {
            ForEach(FlipFX.allCases) { f in
                pick(f.detail, flipFX == f.rawValue) { flipFX = f.rawValue }
            }
        }
        toggleTile("level", "Waterpass", showLevel) { showLevel.toggle() }
        toggleTile("scope", "Peaking", peaking) { peaking.toggle() }
        toggleTile("line.diagonal", "Zebra", zebra) { zebra.toggle() }
        if peaking {
            menuTile(peakColor, "Warna peaking") {
                ForEach(ContentView.peakColors, id: \.self) { c in
                    pick(c, peakColor == c) { peakColor = c }
                }
            }
        }
        if zebra {
            menuTile("\(Int((zebraLevel * 100).rounded()))%", "Level zebra") {
                ForEach([0.70, 0.80, 0.90, 0.95, 1.0], id: \.self) { v in
                    pick("\(Int((v * 100).rounded()))%", abs(zebraLevel - v) < 0.005) { zebraLevel = v }
                }
            }
        }
    }

    // MARK: - lainnya
    @ViewBuilder private var otherTiles: some View {
        menuTile(cam.videoLight.rawValue, "Lampu layar", on: cam.videoLight != .off) {
            ForEach(CameraManager.VideoLight.allCases) { l in
                pick(l.rawValue, cam.videoLight == l) { cam.videoLight = l }
            }
            Text("Untuk kamera depan dan DUAL: tepi preview jadi putih terang untuk menerangi wajah.")
        }
        toggleTile("gyroscope", "Gimbal", cam.gimbalMode) { cam.gimbalMode.toggle() }
        if cam.gimbalMode {
            toggleTile("viewfinder.rectangular", "Panduan gimbal", cam.gimbalGuideOn) { cam.gimbalGuideOn.toggle() }
        }
        toggleTile("gearshape.fill", "Semua setelan", false) { open(.settings) }
    }

    // MARK: - ubin
    private func face(_ value: String, _ title: String, on: Bool, symbol: Bool) -> some View {
        VStack(spacing: 4) {
            Group {
                if symbol { Image(systemName: value) } else { Text(value) }
            }
            .font(.subheadline.weight(.bold))
            .lineLimit(1).minimumScaleFactor(0.55)
            .foregroundStyle(on ? Color.yellow : Color.white)
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(on ? Color.yellow : Color.white.opacity(0.7))
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(on ? Color.yellow.opacity(0.18) : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func toggleTile(_ icon: String, _ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { face(icon, title, on: on, symbol: true) }
            .buttonStyle(.plain)
    }

    private var micShort: String {
        let c = mics.current
        if let r = c.range(of: " (") { return String(c[..<r.lowerBound]) }
        return c
    }

    private func menuTile<C: View>(_ value: String, _ title: String, on: Bool = false,
                                   @ViewBuilder items: () -> C) -> some View {
        let content = items()
        return SoftMenu { content } label: { face(value, title, on: on, symbol: false) }   // v0.41.6: bukan UIMenu
    }

    private func pick(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
