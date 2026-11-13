import SwiftUI

/// Panel pengaturan, dikelompokkan per fungsi dengan penjelasan singkat.
/// Hanya menampilkan pengaturan yang relevan dengan mode aktif.
struct SettingsSheet: View {
    @ObservedObject var cam: CameraManager
    @Binding var showHistogram: Bool
    @Binding var zebra: Bool
    @Binding var peaking: Bool
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
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
                    Text(modeDetail).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Mode: \(modeTitle)")
                }

                if isVideo { videoSection }

                // MARK: hasil foto
                if !isVideo {
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
                    if mode == .hdrplus {
                        Toggle("Jumlah frame otomatis (6-15, menurut cahaya)", isOn: $cam.autoFrames)
                    }
                    if mode.isBurst && !(mode == .hdrplus && cam.autoFrames) {
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
                }

                // MARK: zoom FOTO / HDR+
                if (mode == .heif || mode == .hdrplus) && !isVideo {
                    Section {
                        Picker("Cara zoom", selection: $cam.zoomMethod) {
                            ForEach(CameraManager.ZoomMethod.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Text(cam.zoomMethod.detail).font(.caption).foregroundStyle(.secondary)
                        Toggle("AI setelah zoom", isOn: $cam.zoomAIEnabled)
                        if cam.zoomAIEnabled {
                            Toggle("Fokus tulisan (AI penuh di area teks)", isOn: $cam.textFocus)
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
                        Text("Berlaku saat zoom MELEWATI lensa optik (0.5x / 1x / 2x / 5x tetap lensa asli). Cara zoom = pembesaran dasar; AI = penajaman tambahan di atasnya (mati = Lanczos / Apple apa adanya), jadi semua kombinasi bisa dibandingkan. MALAM selalu Super Res.")
                    }
                }

                // MARK: HDR+
                if mode == .hdrplus {
                    Section {
                        Picker("Metode merge", selection: $cam.mergeMethod) {
                            ForEach(CameraManager.MergeMethod.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
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
                        Text("Frekuensi (default): metode asli HDR+ Google, per tile di domain frekuensi - lebih tahan gerak & detail. Spasial: metode lama. Noise reduction lebih tinggi = lebih halus, risiko bayangan ganda pada objek bergerak. Default 18.")
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
                        Toggle("Fokus tulisan (AI penuh di area teks)", isOn: $cam.textFocus)
                    } header: {
                        Text("AI Zoom")
                    } footer: {
                        Text("Cepat: beberapa detik. Detail: lebih tajam, bisa 40-80 detik untuk 24/48MP - tetap di app sampai selesai. Kekuatan AI 0% = pembesaran biasa, 100% = AI penuh. Multi-frame dipakai di lensa tele atau crop 3x ke atas.")
                    }
                }

                // MARK: eksposur & WB
                Section {
                    Picker("White balance", selection: Binding(get: { cam.wbPreset }, set: { cam.setWBPreset($0) })) {
                        ForEach(CameraManager.WBPreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Timer", selection: $cam.timerSeconds) {
                        Text("Mati").tag(0)
                        Text("3 detik").tag(3)
                        Text("10 detik").tag(10)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("WB & shutter")
                } footer: {
                    Text("Kunci = WB saat ini dikunci (terpisah dari AE/AF). Cerah 5500K, Berawan 6500K, Teduh 7500K, Pijar 3000K, Neon 4000K. Tombol volume juga bisa dipakai sebagai shutter.")
                }

                // MARK: bantuan bidik
                Section {
                    Toggle(isOn: $showHistogram) { Label("Histogram", systemImage: "chart.bar.fill") }
                    Toggle(isOn: $zebra) { Label("Zebra (area hampir putih)", systemImage: "line.diagonal") }
                    Toggle(isOn: $peaking) { Label("Focus peaking (tepi tajam merah)", systemImage: "scope") }
                    Toggle(isOn: $showGrid) { Label("Grid 3x3", systemImage: "grid") }
                    Toggle(isOn: $showLevel) { Label("Waterpass (level horizon)", systemImage: "level") }
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

    private var isVideo: Bool { cam.shootMode == .video }

    @ViewBuilder private var videoSection: some View {
        Section {
            Picker("Resolusi", selection: $cam.videoRes) {
                ForEach(VideoRes.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $cam.videoFps) {
                ForEach(VideoFps.allCases) { Text($0.label).tag($0) }
            }
            if cam.videoFps.isSlowMo {
                Picker("Slow-mo diputar di", selection: $cam.slowPlayback) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                }
                .pickerStyle(.segmented)
            }
            Picker("Time-lapse", selection: $cam.timelapse) {
                Text("Mati").tag(1)
                ForEach([5, 10, 30, 60, 120], id: \.self) { Text("\($0)x").tag($0) }
            }
            Picker("Codec", selection: $cam.videoCodec) {
                ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Warna", selection: $cam.videoColor) {
                ForEach(VideoColor.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Stabilisasi", selection: $cam.videoStab) {
                ForEach(VideoStab.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Shutter 180° otomatis (1/2x fps, ISO menyesuaikan)", isOn: $cam.shutter180)
            if cam.shutter180 {
                Toggle("Kunci lensa otomatis saat rekam (agar 180° aktif)", isOn: $cam.lockLensOnRecord)
            }
            Picker("Zoom halus", selection: $cam.smoothZoom) {
                ForEach(SmoothZoom.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Tajamkan zoom digital (Rec.709 / LUT)", isOn: $cam.sharpenZoom)
            Toggle("Bakar LUT ke video (keluaran Rec.709)", isOn: $cam.bakeLUTVideo)
            Picker("Frame guide", selection: $cam.frameGuide) {
                ForEach(FrameGuide.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Simpan ke", selection: $cam.videoSaveTo) {
                ForEach(VideoSaveTo.allCases) { Text($0.rawValue).tag($0) }
            }
        } header: {
            Text("Video")
        } footer: {
            Text("HEVC = H.265. Apple Log & HLG direkam 10-bit (HEVC / ProRes; H.264 otomatis jadi HEVC). Log tampil di layar sebagai Rec.709 supaya mudah dilihat, file tetap Log untuk di-grade. Slow-mo 120/240 & time-lapse tanpa suara. Zoom: titik ✦ = tanpa crop digital (lensa / crop sensor 48 MP); di luar itu Digital, ditajamkan ringan. Lensa Auto: saat rekam lensa hanya pindah bila zoom diubah. Chip ✨ AI = AI Upscale video setelah rekam. FPS Auto: 60 saat terang, 30 saat gelap (dipilih saat mulai rekam). Files (app) = folder Videos di app, bisa diambil lewat kabel. ProRes 4K ~5-6 GB/menit.")
        }
    }

    private var modeTitle: String {
        switch cam.shootMode {
        case .video: return "VIDEO · \(cam.videoInfo)"
        case .night: return "MALAM"
        case .photo: return "FOTO · \(cam.photoProcess.rawValue)"
        case .pro: return "PRO · \(cam.proFormat.rawValue)"
        }
    }

    private var modeDetail: String {
        switch cam.shootMode {
        case .video: return "Video ala Blackmagic Camera: 4K/1080p, 24-60 fps, slow-mo 120/240, time-lapse, HEVC / H.264 / ProRes, Rec.709 / HLG / Apple Log, stabilisasi, shutter 180°, frame guide, meter audio, senter. Laci Pro: ISO, shutter, WB, fokus manual."
        case .night: return "HDR+ dengan shutter lebih lama (genggam 1/4 s, tele 1/8 s, HP diam/tripod sampai 1 s) dan ISO lebih rendah, 6-15 frame, lalu dicerahkan. Tahan HP sampai selesai."
        case .photo: return cam.photoProcess.detail
        case .pro: return cam.proFormat.detail + ". Laci Pro (ikon slider kanan bawah): EV, ISO, shutter, WB, fokus manual per bagian."
        }
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
