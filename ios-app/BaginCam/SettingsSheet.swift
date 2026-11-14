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
                        Toggle("Fusi detail 48MP (cahaya cukup, 0.5x / 1x)", isOn: $cam.fusion48)
                        if cam.fusion48 { Toggle("Simpan foto 48MP mentah (debug)", isOn: $cam.debugFusion) }
                    } header: {
                        Text("HDR+")
                    } footer: {
                        Text("Frekuensi (default): metode asli HDR+ Google, per tile di domain frekuensi - lebih tahan gerak & detail. Spasial: metode lama. Noise reduction lebih tinggi = lebih halus, risiko bayangan ganda pada objek bergerak. Default 18. Fusi 48MP: setelah burst diambil 1 foto Apple 48MP; warna & HDR dari HDR+, detail halus dari sensor 48MP (+2-3 detik). Saat gelap / zoom / MALAM otomatis tidak dipakai.")
                    }
                }

                // MARK: Tuning ala AGC (v0.14)
                if !isVideo && (mode == .hdrplus || mode == .aiZoom || mode == .heif) { tuningSections }

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
                    HStack(spacing: 14) {
                        Image("Logo").resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BaginCam").font(.headline)
                            Text(LogFile.model).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Lensa aktif", value: cam.activeLensLabel)
                    LabeledContent("Versi", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    LabeledContent("Log hari ini", value: LogFile.todaySize)
                    ShareLink(item: LogFile.todayURL) { Label("Bagikan log", systemImage: "square.and.arrow.up") }
                } header: {
                    Text("Info")
                } footer: {
                    Text("Log tersimpan di app (Files > BaginCam > Logs), jadi bisa tes tanpa kabel. Saat \"cek\", colok kabel sebentar.")
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
        .onAppear { LogFile.shared.flush() }
    }

    private var isVideo: Bool { cam.shootMode == .video }

    @ViewBuilder private var tuningSections: some View {
            Section {
                Menu {
                    ForEach(PhotoTuning.presets.indices, id: \.self) { i in
                    let p = PhotoTuning.presets[i]
                        Button { cam.tuning = p.1 } label: {
                            if cam.tuning == p.1 { Label(p.0, systemImage: "checkmark") } else { Text(p.0) }
                        }
                    }
                } label: {
                    HStack {
                        Label("Preset", systemImage: "slider.horizontal.3")
                        Spacer()
                        Text(tuningPresetName).foregroundStyle(.secondary)
                    }
                }
                tuneSlider("Ketajaman", \.sharpness, 0...2, "%.2fx")
                tuneSlider("Detail halus", \.detail, 0...2, "%.2fx")
                tuneSlider("NR luma (butiran)", \.lumaNR, 0...1.5, "%.2fx")
                tuneSlider("NR warna (bintik warna)", \.chromaNR, 0...1.5, "%.2fx")
                tuneSlider("HDR lokal", \.localTone, 0...1, "%.2f")
                tuneSlider("EV tambahan", \.exposure, -1...1, "%+.1f EV", step: 0.1)
            } header: {
                Text("Tuning RAW (ala AGC)")
            } footer: {
                Text("Diterapkan saat RAW hasil merge dikembangkan (HDR+, MALAM, Super Res / AI Zoom multi-frame). Ketajaman & detail lebih tinggi + NR luma lebih rendah = tekstur lebih banyak tapi butiran naik. HDR lokal = bayangan diangkat, langit ditahan.")
            }
            Section {
                tuneSlider("Penajaman akhir", \.finalSharpen, 0...1, "%.2f")
                if cam.tuning.finalSharpen > 0.01 {
                    tuneSlider("Radius penajaman", \.finalRadius, 0.5...4, "%.1f px", step: 0.1)
                }
                tuneSlider("Bayangan", \.shadows, -1...1, "%+.2f")
                tuneSlider("Selamatkan highlight", \.highlights, 0...1, "%.2f")
                tuneSlider("Kontras", \.contrast, -1...1, "%+.2f")
                tuneSlider("Saturasi (vibrance)", \.saturation, -1...1, "%+.2f")
                Button("Kembali ke bawaan (Natural)", role: .destructive) { cam.tuning = PhotoTuning() }
                    .disabled(cam.tuning.isDefault)
            } header: {
                Text("Tuning akhir (setelah zoom)")
            } footer: {
                Text("Dijalankan di resolusi akhir, setelah Super Res / AI memperbesar - penajaman akhir di sini yang paling terasa untuk zoom. Radius kecil (1-1.5 px) = tekstur halus, besar (2-4 px) = tepi tebal. Berlaku juga untuk AI Zoom foto biasa. Tidak berlaku untuk foto proses Apple, ProRAW, dan video.")
            }
    }

    private var tuningPresetName: String {
        PhotoTuning.presets.first { $0.1 == cam.tuning }?.0 ?? "Kustom"
    }

    /// slider tuning (nilai dibulatkan ke `step`)
    private func tuneSlider(_ title: String, _ kp: WritableKeyPath<PhotoTuning, Double>, _ range: ClosedRange<Double>,
                            _ fmt: String, step: Double = 0.05) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: fmt, cam.tuning[keyPath: kp])).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { cam.tuning[keyPath: kp] },
                                  set: { cam.tuning[keyPath: kp] = ($0 / step).rounded() * step }), in: range)
        }
    }

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
        case .video: return "Video ala Blackmagic Camera: 4K/1080p/720p, 24-60 fps, slow-mo 120/240, time-lapse, HEVC / H.264 / ProRes, Rec.709 / HLG / Apple Log, stabilisasi, shutter 180°, frame guide, meter audio, senter. Laci Pro: ISO, shutter, WB, fokus manual."
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
