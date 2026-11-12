import SwiftUI

/// Panel pengaturan, dikelompokkan per fungsi dengan penjelasan singkat.
/// Hanya menampilkan pengaturan yang relevan dengan mode aktif.
struct SettingsSheet: View {
    @ObservedObject var cam: CameraManager
    @Binding var showHistogram: Bool
    @Binding var zebra: Bool
    @Binding var peaking: Bool
    @Binding var showGrid: Bool
    let hasLUT: Bool
    @Environment(\.dismiss) private var dismiss

    private var mode: CameraManager.Mode { cam.mode }

    static func showsResolution(_ cam: CameraManager) -> Bool {
        switch cam.mode {
        case .heif, .proraw: return cam.maxMP > 20
        case .hdrplus: return cam.outputFormat != .dng
        case .aiZoom: return true
        case .bayer: return false
        }
    }

    private var lutAllowed: Bool {
        hasLUT && mode != .bayer && mode != .proraw && !(mode == .hdrplus && cam.outputFormat == .dng)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(mode.detail).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Mode: \(mode.rawValue)")
                }

                // MARK: hasil foto
                Section {
                    if mode == .hdrplus {
                        Picker("Format", selection: $cam.outputFormat) {
                            ForEach(PhotoFormat.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    if Self.showsResolution(cam) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Resolusi")
                            Picker("Resolusi", selection: $cam.outputMP) {
                                ForEach(OutputMP.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    if mode.isBurst {
                        Stepper("Jumlah frame: \(cam.burstCount)", value: $cam.burstCount, in: 2...16)
                    }
                    if mode == .hdrplus {
                        Toggle("Simpan juga frame mentah (DNG)", isOn: $cam.saveFrames)
                    }
                    if lutAllowed {
                        Toggle("Bakar LUT ke foto", isOn: $cam.bakeLUT)
                    }
                } header: {
                    Text("Hasil foto")
                } footer: {
                    Text(resultFooter)
                }

                // MARK: zoom FOTO / HDR+
                if mode == .heif || mode == .hdrplus {
                    Section {
                        Toggle("Pakai AI saat zoom", isOn: $cam.zoomAIEnabled)
                        if cam.zoomAIEnabled {
                            Picker("Model AI", selection: $cam.srModel) {
                                ForEach(SRModel.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("Kekuatan AI")
                                    Spacer()
                                    Text("\(Int((cam.aiStrength * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                                }
                                Slider(value: $cam.aiStrength, in: 0...1)
                            }
                        }
                    } header: {
                        Text("Zoom")
                    } footer: {
                        Text(mode == .hdrplus
                             ? "HDR+ + zoom = gabung 8 frame dulu (detail asli, noise turun) lalu di-crop & diperbesar. Matikan AI untuk membandingkan: pembesaran biasa (Lanczos) vs AI."
                             : "Foto diambil resolusi penuh (48MP lensa utama) lalu di-crop & diperbesar. Matikan AI untuk membandingkan hasil tanpa AI.")
                    }
                }

                // MARK: HDR+
                if mode == .hdrplus {
                    Section {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Noise reduction")
                                Spacer()
                                Text("\(Int(cam.hdrNoiseReduction))").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: $cam.hdrNoiseReduction, in: 1...23, step: 1)
                        }
                    } header: {
                        Text("HDR+")
                    } footer: {
                        Text("Lebih tinggi = frame lebih banyak digabung (lebih halus), tapi risiko bayangan ganda pada objek bergerak. Default 18.")
                    }
                }

                // MARK: AI Zoom
                if mode == .aiZoom {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Model AI")
                            Picker("Model AI", selection: $cam.srModel) {
                                ForEach(SRModel.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .disabled(!cam.srDetailAvailable)
                        }
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Kekuatan AI")
                                Spacer()
                                Text("\(Int((cam.aiStrength * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: $cam.aiStrength, in: 0...1)
                        }
                        Toggle("Multi-frame (8 frame digabung)", isOn: $cam.multiFrameZoom)
                    } header: {
                        Text("AI Zoom")
                    } footer: {
                        Text("Cepat: beberapa detik. Detail: lebih tajam, bisa 40-80 detik untuk 24/48MP - tetap di app sampai selesai. Kekuatan AI 0% = pembesaran biasa, 100% = AI penuh. Multi-frame dipakai di lensa tele atau crop 3x ke atas.")
                    }
                }

                // MARK: bantuan bidik
                Section {
                    Toggle(isOn: $showHistogram) { Label("Histogram", systemImage: "chart.bar.fill") }
                    Toggle(isOn: $zebra) { Label("Zebra (area hampir putih)", systemImage: "line.diagonal") }
                    Toggle(isOn: $peaking) { Label("Focus peaking (tepi tajam merah)", systemImage: "scope") }
                    Toggle(isOn: $showGrid) { Label("Grid 3x3", systemImage: "grid") }
                } header: {
                    Text("Bantuan bidik")
                } footer: {
                    Text("Hanya tampil di layar, tidak ikut tersimpan di foto. Ketuk preview = fokus & eksposur di titik itu; tekan lama = kunci AE/AF.")
                }

                Section {
                    LabeledContent("Lensa aktif", value: cam.activeLensLabel)
                    LabeledContent("Versi", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                } header: {
                    Text("Info")
                }
            }
            .navigationTitle("Pengaturan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Selesai") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var resultFooter: String {
        switch mode {
        case .hdrplus:
            return "HEIF/JPEG: foto siap pakai. DNG: RAW hasil merge untuk diedit (Lightroom). 24/48MP pada HDR+ = diperbesar dari 12MP (AI + Lanczos)."
        case .heif:
            return "24MP diambil dari sensor 48MP lalu diperkecil (detail asli)."
        case .proraw:
            return "Apple ProRAW. 24/48MP memakai sensor 48MP."
        case .bayer:
            return "Bayer RAW mentah (DNG) per frame, untuk diproses di PC."
        case .aiZoom:
            return "Resolusi akhir foto AI Zoom."
        }
    }
}
