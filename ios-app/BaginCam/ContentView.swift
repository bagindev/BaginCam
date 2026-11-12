import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @StateObject private var luts = LUTLibrary()
    @State private var renderer = PreviewRenderer()
    @State private var showManual = false
    @State private var showImporter = false
    @State private var histogram: [Float] = []
    @State private var showHistogram = true
    @State private var zebra = false
    @State private var peaking = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                topBar
                toolRow
                MetalPreview(renderer: renderer)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipped()
                    .overlay(alignment: .bottomLeading) { readout }
                    .overlay(alignment: .topTrailing) {
                        if showHistogram && !histogram.isEmpty { HistogramView(bins: histogram).padding(8) }
                    }
                    .overlay(alignment: .topLeading) { lensBadge }
                if cam.mode == .aiZoom { zoomRow }
                Spacer(minLength: 0)
                if showManual { manualPanel }
                if cam.mode != .aiZoom { lensRow }
                bottomBar
            }
            .padding(.horizontal, 12)
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

    // MARK: atas: LUT, mode, burst
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

            Menu {
                ForEach(CameraManager.Mode.allCases) { m in
                    Button {
                        cam.setMode(m)
                    } label: {
                        Text(m.rawValue)
                        Text(m.detail)
                    }
                    .disabled((m.usesBayer && !cam.supportsBayer) || (m == .proraw && !cam.supportsProRAW))
                }
            } label: {
                chip(cam.mode.rawValue, icon: cam.mode == .hdrplus ? "square.stack.3d.up.fill" : "doc.badge.gearshape")
            }

            Spacer()
            if cam.mode.isBurst {
                Stepper(value: $cam.burstCount, in: 2...16) {
                    Text("x\(cam.burstCount)").font(.footnote.monospacedDigit()).foregroundStyle(.white)
                }
                .fixedSize()
            }
        }
        .padding(.top, 6)
    }

    // MARK: baris alat: histogram, zebra, peaking, 48MP, frame mentah
    private var toolRow: some View {
        // bisa digeser kiri/kanan: di layar sempit tombol paling kanan tidak terpotong lagi (v0.6.3)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // pengaturan khusus mode di depan supaya langsung terlihat
                if cam.mode == .hdrplus {
                    menuChip(cam.outputFormat.rawValue, icon: "photo") {
                        ForEach(PhotoFormat.allCases) { f in
                            Button(f.rawValue) { cam.outputFormat = f }
                        }
                    }
                    toggleChip("+Frame", icon: "square.stack", isOn: $cam.saveFrames)
                }
                if showsResolution {
                    menuChip(cam.outputMP.label, icon: "square.resize.up") {
                        ForEach(OutputMP.allCases) { r in
                            Button(r.label) { cam.outputMP = r }
                        }
                    }
                }
                if cam.mode != .bayer && cam.mode != .proraw && luts.selected != nil
                    && !(cam.mode == .hdrplus && cam.outputFormat == .dng) {
                    toggleChip("LUT", icon: "wand.and.stars", isOn: $cam.bakeLUT)
                }
                toggleChip("Histo", icon: "chart.bar.fill", isOn: $showHistogram)
                toggleChip("Zebra", icon: "line.diagonal", isOn: $zebra)
                toggleChip("Peaking", icon: "scope", isOn: $peaking)
            }
            .padding(.trailing, 12)
        }
    }

    private func menuChip<Content: View>(_ text: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            Label(text, systemImage: icon)
                .font(.caption2).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.22), in: Capsule())
                .overlay(Capsule().stroke(Color.yellow.opacity(0.6), lineWidth: 1))
                .foregroundStyle(.white)
        }
    }

    private func toggleChip(_ text: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Label(text, systemImage: icon)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(isOn.wrappedValue ? Color.yellow.opacity(0.85) : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(isOn.wrappedValue ? .black : .white)
        }
    }

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white)
    }

    private var readout: some View {
        Text("ISO \(Int(cam.liveISO))  \(Self.shutterText(cam.liveShutter))  \(Int(cam.liveTemp))K  F\(String(format: "%.2f", cam.liveLens))")
            .font(.caption.monospacedDigit())
            .padding(6)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(cam.isAuto ? .white : .yellow)
            .padding(8)
    }

    // MARK: AI Zoom
    private var showsResolution: Bool {
        switch cam.mode {
        case .heif, .proraw: return cam.maxMP > 20
        case .hdrplus: return cam.outputFormat != .dng
        case .aiZoom: return true
        case .bayer: return false
        }
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

    /// slider 0..1 -> zoom 1..max skala logaritmik
    private var zoomBinding: Binding<Double> {
        Binding(
            get: { log(Double(cam.totalZoom)) / log(Double(max(cam.maxTotalZoom, 1.01))) },
            set: { t in cam.setTotalZoom(CGFloat(pow(Double(max(cam.maxTotalZoom, 1.01)), t))) })
    }

    private var zoomRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ForEach([1.0, 2.0, 5.0, 10.0, 25.0].filter { CGFloat($0) <= cam.maxTotalZoom + 0.01 }, id: \.self) { z in
                    Button(z == 1 ? "1x" : String(format: "%.0fx", z)) { cam.setTotalZoom(CGFloat(z)) }
                        .font(.caption.bold())
                        .frame(width: 40, height: 28)
                        .background(abs(Double(cam.totalZoom) - z) < 0.05 ? Color.yellow : Color.white.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(abs(Double(cam.totalZoom) - z) < 0.05 ? .black : .white)
                }
                Spacer(minLength: 0)
                Text(String(format: "%.1fx", Double(cam.totalZoom)))
                    .font(.callout.monospacedDigit().bold()).foregroundStyle(.yellow)
            }
            Slider(value: zoomBinding, in: 0...1)
            HStack(spacing: 8) {
                Picker("Model", selection: $cam.srModel) {
                    ForEach(SRModel.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .disabled(!cam.srDetailAvailable)
                if cam.supportsBayer {
                    toggleChip("Multi-frame", icon: "square.stack.3d.down.right", isOn: $cam.multiFrameZoom)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("Kekuatan AI").font(.caption).foregroundStyle(.white)
                Slider(value: $cam.aiStrength, in: 0...1)
                Text("\(Int((cam.aiStrength * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white).frame(width: 40)
            }
            if !cam.srFastAvailable {
                Text("model AI belum ada di build ini - pembesaran biasa").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
            if cam.mode == .hdrplus {
                sliderRow("HDR+ NR", value: "\(Int(cam.hdrNoiseReduction))") {
                    Slider(value: $cam.hdrNoiseReduction, in: 1...23, step: 1)
                }
            }
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

    // MARK: bawah: status + shutter
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
                Image(systemName: showManual ? "slider.horizontal.below.square.filled.and.square" : "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.bottom, 10)
    }
}
