import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @StateObject private var luts = LUTLibrary()
    @State private var renderer = PreviewRenderer()
    @State private var showManual = false
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var histogram: [Float] = []
    @State private var showHistogram = true
    @State private var zebra = false
    @State private var peaking = false

    /// urutan mode di strip (seperti kamera bawaan)
    private let modeOrder: [CameraManager.Mode] = [.aiZoom, .hdrplus, .heif, .proraw, .bayer]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                topBar
                MetalPreview(renderer: renderer)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipped()
                    .overlay(alignment: .bottomLeading) { readout }
                    .overlay(alignment: .topTrailing) {
                        if showHistogram && !histogram.isEmpty { HistogramView(bins: histogram).padding(8) }
                    }
                    .overlay(alignment: .topLeading) { lensBadge }
                    .overlay(alignment: .bottomTrailing) { assistBadges }
                if cam.mode == .aiZoom { zoomRow }
                Spacer(minLength: 0)
                if showManual { manualPanel }
                if cam.mode != .aiZoom { lensRow }
                modeStrip
                bottomBar
            }
            .padding(.horizontal, 12)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(cam: cam, showHistogram: $showHistogram, zebra: $zebra, peaking: $peaking,
                          hasLUT: luts.selected != nil)
        }
        .onAppear {
            let r = renderer
            cam.onFrame = { image in r.push(image) }
            r.onHistogram = { bins in histogram = bins }
            cam.start()
            if luts.selected == nil {
                luts.select(luts.items.first { $0.name.contains("STANDARD") } ?? luts.items.first)
            }
        }
        .onChange(of: luts.filter) { _, newFilter in renderer.lutFilter = newFilter; cam.captureLUT = luts.current }
        .onChange(of: zebra) { _, v in renderer.zebra = v }
        .onChange(of: peaking) { _, v in renderer.peaking = v }
        .onChange(of: showHistogram) { _, v in renderer.histogramEnabled = v; if !v { histogram = [] } }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
            if case .success(let url) = result { luts.importLUT(from: url) }
        }
    }

    // MARK: atas: LUT + ringkasan pengaturan
    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Tanpa LUT") { luts.select(nil) }
                ForEach(luts.items) { item in
                    Button(item.name) { luts.select(item) }
                }
                Divider()
                Button("Import .cube...") { showImporter = true }
            } label: {
                chip(luts.selected?.name.replacingOccurrences(of: "SonyLook_", with: "") ?? "LUT: off",
                     icon: "camera.filters")
            }
            Spacer(minLength: 4)
            Button { showSettings = true } label: {
                HStack(spacing: 6) {
                    Text(settingsSummary).font(.footnote).lineLimit(1)
                    Image(systemName: "gearshape.fill")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.16), in: Capsule())
                .overlay(Capsule().stroke(Color.yellow.opacity(0.7), lineWidth: 1))
                .foregroundStyle(.white)
            }
        }
        .padding(.top, 6)
    }

    /// ringkasan pengaturan aktif, mis. "HEIF · 12MP · 8 frame"
    private var settingsSummary: String {
        var parts: [String] = []
        switch cam.mode {
        case .hdrplus:
            parts.append(cam.outputFormat.rawValue)
            if cam.outputFormat != .dng { parts.append(cam.outputMP.label) }
            parts.append("\(cam.burstCount) frame")
            if cam.saveFrames { parts.append("+mentah") }
        case .aiZoom:
            parts.append(cam.srModel.rawValue)
            parts.append("AI \(Int((cam.aiStrength * 100).rounded()))%")
            parts.append(cam.outputMP.label)
            if cam.multiFrameZoom { parts.append("MF") }
        case .heif, .proraw:
            if SettingsSheet.showsResolution(cam) { parts.append(cam.outputMP.label) }
            parts.append("\(cam.burstCount) frame")
        case .bayer:
            parts.append("\(cam.burstCount) frame")
        }
        if cam.bakeLUT && luts.selected != nil && cam.mode != .bayer && cam.mode != .proraw { parts.append("LUT") }
        return parts.joined(separator: " · ")
    }

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white)
    }

    // MARK: overlay preview
    private var readout: some View {
        Text("ISO \(Int(cam.liveISO))  \(Self.shutterText(cam.liveShutter))  \(Int(cam.liveTemp))K  F\(String(format: "%.2f", cam.liveLens))")
            .font(.caption.monospacedDigit())
            .padding(6)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(cam.isAuto ? .white : .yellow)
            .padding(8)
    }

    /// penanda lensa fisik yang sedang dipakai (mis. "Tele 5x", "Utama 1x · crop 7.0x")
    private var lensBadge: some View {
        Label(cam.activeLensLabel, systemImage: "camera.aperture")
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(cam.activeLensLabel.contains("crop") ? .orange : .yellow)
            .padding(8)
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

    // MARK: AI Zoom
    /// slider 0..1 -> zoom 1..max skala logaritmik
    private var zoomBinding: Binding<Double> {
        Binding(
            get: { log(Double(cam.totalZoom)) / log(Double(max(cam.maxTotalZoom, 1.01))) },
            set: { t in cam.setTotalZoom(CGFloat(pow(Double(max(cam.maxTotalZoom, 1.01)), t))) })
    }

    private var zoomRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach([1.0, 2.0, 5.0, 10.0, 25.0].filter { CGFloat($0) <= cam.maxTotalZoom + 0.01 }, id: \.self) { z in
                    let on = abs(Double(cam.totalZoom) - z) < 0.05
                    Button(z == 1 ? "1x" : String(format: "%.0fx", z)) { cam.setTotalZoom(CGFloat(z)) }
                        .font(.caption.bold())
                        .frame(width: 40, height: 28)
                        .background(on ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(on ? .black : .white)
                }
                Spacer(minLength: 0)
                Text(String(format: "%.1fx", Double(cam.totalZoom)))
                    .font(.callout.monospacedDigit().bold()).foregroundStyle(.yellow)
            }
            Slider(value: zoomBinding, in: 0...1).tint(.yellow)
        }
    }

    // MARK: lensa
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

    // MARK: strip mode (ketuk untuk ganti)
    private func modeLabel(_ m: CameraManager.Mode) -> String {
        switch m {
        case .aiZoom: return "AI ZOOM"
        case .hdrplus: return "HDR+"
        case .heif: return "FOTO"
        case .proraw: return "PRORAW"
        case .bayer: return "BAYER"
        }
    }

    private func modeAvailable(_ m: CameraManager.Mode) -> Bool {
        if m == .aiZoom { return true }   // AI Zoom memilih lensa sendiri
        return !((m.usesBayer && !cam.supportsBayer) || (m == .proraw && !cam.supportsProRAW))
    }

    private var modeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(modeOrder) { m in
                        let on = cam.mode == m
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { cam.setMode(m) }
                        } label: {
                            Text(modeLabel(m))
                                .font(.footnote.weight(on ? .bold : .semibold))
                                .foregroundStyle(on ? .yellow : (modeAvailable(m) ? .white : .gray))
                                .padding(.vertical, 4)
                        }
                        .disabled(cam.isCapturing || !modeAvailable(m))
                        .id(m)
                    }
                }
                .padding(.horizontal, 60)
            }
            .onAppear { proxy.scrollTo(cam.mode, anchor: .center) }
            .onChange(of: cam.mode) { _, m in withAnimation { proxy.scrollTo(m, anchor: .center) } }
        }
        .frame(height: 28)
    }

    // MARK: panel manual
    private var manualPanel: some View {
        VStack(spacing: 6) {
            Toggle("Auto (AE / AWB / AF)", isOn: Binding(get: { cam.isAuto }, set: { cam.setAuto($0) }))
                .font(.footnote)
            Group {
                sliderRow("ISO", value: "\(Int(cam.iso))") {
                    Slider(value: Binding(get: { cam.iso }, set: { cam.iso = $0; cam.applyManual() }),
                           in: cam.isoRange)
                }
                sliderRow("Shutter", value: Self.shutterText(cam.shutter)) {
                    Slider(value: shutterBinding, in: 0...1)
                }
                sliderRow("WB", value: "\(Int(cam.temperature))K") {
                    Slider(value: Binding(get: { cam.temperature }, set: { cam.temperature = $0; cam.applyManual() }),
                           in: 2500...9000)
                }
                sliderRow("Fokus", value: String(format: "%.2f", cam.lensPosition)) {
                    Slider(value: Binding(get: { cam.lensPosition }, set: { cam.lensPosition = $0; cam.applyManual() }),
                           in: 0...1)
                }
            }
            .disabled(cam.isAuto)
            .opacity(cam.isAuto ? 0.4 : 1)
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }

    private func sliderRow<S: View>(_ title: String, value: String, @ViewBuilder slider: () -> S) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 56, alignment: .leading)
            slider()
            Text(value).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
        }
    }

    /// slider 0..1 -> shutter skala logaritmik
    private var shutterBinding: Binding<Double> {
        Binding(
            get: {
                let r = cam.shutterRange
                return log(cam.shutter / r.lowerBound) / log(r.upperBound / r.lowerBound)
            },
            set: { t in
                let r = cam.shutterRange
                cam.shutter = r.lowerBound * pow(r.upperBound / r.lowerBound, t)
                cam.applyManual()
            })
    }

    static func shutterText(_ s: Double) -> String {
        guard s > 0 else { return "-" }
        return s >= 0.5 ? String(format: "%.1fs", s) : "1/\(Int((1 / s).rounded()))"
    }

    // MARK: bawah: status + shutter + manual
    private var bottomBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let p = cam.progress {
                    ProgressView(value: p).tint(.yellow)
                }
                Text(cam.status)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: cam.startBurst) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    Circle().fill(cam.isCapturing ? .red : (cam.mode == .hdrplus ? .yellow : .white))
                        .frame(width: 62, height: 62)
                    if cam.isCapturing { ProgressView().tint(.white) }
                }
            }
            .disabled(cam.isCapturing)

            Button { withAnimation { showManual.toggle() } } label: {
                VStack(spacing: 2) {
                    Image(systemName: showManual ? "slider.horizontal.below.square.filled.and.square" : "slider.horizontal.3")
                        .font(.title2)
                    Text("Manual").font(.caption2)
                }
                .foregroundStyle(showManual || !cam.isAuto ? .yellow : .white)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.bottom, 10)
    }
}
