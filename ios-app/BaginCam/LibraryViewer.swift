import AVKit
import Photos
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - Galeri ala kamera bawaan (v0.16): geser foto / video terbaru dari album Foto

struct LibraryViewer: View {
    /// cadangan bila izin album ditolak: foto terakhir dari app
    var fallbackData: Data?
    var fallbackName: String
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var index = 0
    @State private var loaded = false
    @State private var denied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !loaded {
                ProgressView().tint(.white)
            } else if assets.isEmpty {
                PhotoViewer(data: fallbackData, name: fallbackName)
                if denied {
                    VStack {
                        Spacer()
                        Text("Izinkan akses Foto (Pengaturan > BaginCam > Foto > Semua Foto) supaya bisa menggeser album seperti kamera bawaan.")
                            .font(.caption).multilineTextAlignment(.center).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.bottom, 40).padding(.horizontal, 20)
                    }
                }
            } else {
                TabView(selection: $index) {
                    ForEach(assets.indices, id: \.self) { i in
                        AssetPage(asset: assets[i], active: i == index).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
                topBar
            }
        }
        .statusBarHidden(true)
        .task { await load() }
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                circleButton("xmark") { dismiss() }
                Spacer()
                VStack(spacing: 1) {
                    Text(dateText).font(.caption.bold())
                    Text("\(index + 1) / \(assets.count)").font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                Spacer()
                circleButton("trash") { deleteCurrent() }
                circleButton("photo.on.rectangle") {
                    if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            Spacer()
        }
    }

    private func circleButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.headline)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.6), in: Circle())
        }
    }

    private var dateText: String {
        guard assets.indices.contains(index), let d = assets[index].creationDate else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'Hari ini' HH.mm" : "d MMM yyyy HH.mm"
        return f.string(from: d)
    }

    private func load() async {
        var st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if st == .notDetermined { st = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        if st == .authorized || st == .limited {
            assets = Self.recent(limit: 150)
        } else {
            denied = true
        }
        index = 0
        loaded = true
    }

    static func recent(limit: Int) -> [PHAsset] {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.fetchLimit = limit
        let r = PHAsset.fetchAssets(with: o)
        var a: [PHAsset] = []
        r.enumerateObjects { x, _, _ in if x.mediaType == .image || x.mediaType == .video { a.append(x) } }
        return a
    }

    /// thumbnail aset terbaru (tanpa meminta izin) untuk tombol galeri
    static func latestThumb(_ done: @escaping (UIImage) -> Void) {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard st == .authorized || st == .limited, let a = recent(limit: 1).first else { return }
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 240, height: 240), contentMode: .aspectFill,
                                              options: o) { img, _ in
            if let img { DispatchQueue.main.async { done(img) } }
        }
    }

    private func deleteCurrent() {
        guard assets.indices.contains(index) else { return }
        let a = assets[index]
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([a] as NSArray)
        }) { ok, _ in
            guard ok else { return }
            DispatchQueue.main.async {
                assets.removeAll { $0.localIdentifier == a.localIdentifier }
                if assets.isEmpty { dismiss() } else { index = min(index, assets.count - 1) }
            }
        }
    }
}

/// satu halaman: foto (cubit / ketuk 2x untuk zoom) atau video (diputar saat halaman aktif)
private struct AssetPage: View {
    let asset: PHAsset
    let active: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if asset.mediaType == .video {
                if let player, active {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                    Image(systemName: "play.circle.fill").font(.system(size: 60)).foregroundStyle(.white.opacity(0.85))
                }
            } else if let image {
                ZoomableImage(image: image)
            }
            if image == nil && player == nil { ProgressView().tint(.white) }
        }
        .task(id: asset.localIdentifier) { requestImage() }
        .onAppear { if active { preparePlayer() } }
        .onChange(of: active) { _, a in
            if a { preparePlayer() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }

    private func requestImage() {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic          // cepat (buram) lalu tajam
        o.isNetworkAccessAllowed = true
        o.resizeMode = .exact
        let side: CGFloat = asset.mediaType == .video ? 1600 : 4032
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                              contentMode: .aspectFit, options: o) { img, _ in
            if let img { DispatchQueue.main.async { image = img } }
        }
    }

    private func preparePlayer() {
        guard asset.mediaType == .video else { return }
        if let player { player.play(); return }
        let o = PHVideoRequestOptions()
        o.isNetworkAccessAllowed = true
        o.deliveryMode = .automatic
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: o) { item, _ in
            guard let item else { return }
            DispatchQueue.main.async {
                let p = AVPlayer(playerItem: item)
                player = p
                if active { p.play() }
            }
        }
    }
}

// MARK: - pendeteksi sentuhan tanpa mengganggu scroll (v0.16)
// v0.15 memakai simultaneousGesture(DragGesture) di root -> di iOS 18 ScrollView chip tidak bisa digeser.
// Sekarang: gesture recognizer "mata-mata" di UIWindow yang langsung gagal (tidak pernah menahan sentuhan).

final class TouchSpy: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

struct TouchSpyView: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.isUserInteractionEnabled = false
        v.onTouch = onTouch
        return v
    }

    func updateUIView(_ v: Host, context: Context) { v.onTouch = onTouch }

    final class Host: UIView {
        var onTouch: (() -> Void)?
        private var spy: TouchSpy?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let w = window, spy == nil else { return }
            let s = TouchSpy(target: nil, action: nil)
            s.onTouch = { [weak self] in self?.onTouch?() }
            w.addGestureRecognizer(s)
            spy = s
        }
    }
}
