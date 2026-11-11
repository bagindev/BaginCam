import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @StateObject private var luts = LUTLibrary()
    @State private var renderer = PreviewRenderer()
    @State private var showManual = false
    @State private var showImporter = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                topBar
                MetalPreview(renderer: renderer)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipped()
                    .overlay(alignment: .bottomLeading) { readout }
                Spacer(minLength: 0)
                if showManual { manualPanel }
                bottomBar
            }
            .padding(.horizontal, 12)
        }
        .onAppear {
            let r = renderer
            cam.onFrame = { image in r.push(image) }
            cam.start()
            if luts.selected == nil {
                luts.select(luts.items.first { $0.name.contains("STANDARD") } ?? luts.items.first)
            }
        }
        .onChange(of: luts.filter) { _, newFilter in renderer.lutFilter = newFilter }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
            if case .success(let url) = result { luts.importLUT(from: url) }
        }
    }

    // MARK: atas: LUT, format, burst
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
                ForEach(CameraManager.RawMode.allCases) { mode in
                    Button(mode.rawValue) { cam.setRawMode(mode) }
                        .disabled((mode == .bayer && !cam.supportsBayer) || (mode == .proraw && !cam.supportsProRAW))
                }
            } label: {
                chip(cam.rawMode.rawValue, icon: "doc.badge.gearshape")
            }

            Spacer()
            Stepper(value: $cam.burstCount, in: 1...16) {
                Text("x\(cam.burstCount)").font(.footnote.monospacedDigit()).foregroundStyle(.white)
            }
            .fixedSize()
        }
        .padding(.top, 6)
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
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
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
            Text(cam.status)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            Button(action: cam.startBurst) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    Circle().fill(cam.isCapturing ? .red : .white).frame(width: 62, height: 62)
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
