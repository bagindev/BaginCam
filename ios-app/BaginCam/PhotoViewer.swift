import SwiftUI
import UIKit
import ImageIO

/// Penampil foto terakhir di dalam app: cubit / ketuk 2x untuk zoom (cek detail AI) tanpa membuka Galeri.
struct PhotoViewer: View {
    let data: Data?
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.6), in: Circle())
                    }
                    Spacer()
                    Text(name).font(.caption).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                    Spacer()
                    Button {
                        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                    } label: {
                        Image(systemName: "photo.on.rectangle").font(.headline)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.6), in: Circle())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                Spacer()
                if let image {
                    Text("\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale)) · cubit / ketuk 2x untuk zoom")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 10)
                }
            }
        }
        .task {
            guard image == nil, let data else { return }
            image = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
        }
    }

    /// decode tegak (orientasi diterapkan), maks 8064 px sisi panjang
    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 8064]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// UIScrollView + UIImageView: zoom 1-10x, ketuk 2x = 1x / 3x
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.backgroundColor = .black
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 10
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.delegate = context.coordinator
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.frame = sv.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sv.addSubview(iv)
        context.coordinator.imageView = iv
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(tap)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            if sv.zoomScale > 1.01 {
                sv.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let s: CGFloat = 3
                let w = sv.bounds.width / s, h = sv.bounds.height / s
                sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}
