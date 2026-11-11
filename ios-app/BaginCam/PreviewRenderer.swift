import SwiftUI
import MetalKit
import CoreImage

/// Render frame kamera + LUT ke layar dengan Metal (Core Image di GPU).
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let ciContext: CIContext
    private let lock = NSLock()
    private var latest: CIImage?

    /// Diakses hanya dari main thread (draw MTKView berjalan di main).
    var lutFilter: CIFilter?

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    /// Dipanggil dari antrean video kamera.
    func push(_ image: CIImage) {
        lock.lock(); latest = image; lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock(); let frame = latest; lock.unlock()
        guard var image = frame,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        if let f = lutFilter {
            f.setValue(image, forKey: kCIInputImageKey)
            if let out = f.outputImage { image = out }
        }

        // aspect-fill ke ukuran layar
        let ds = view.drawableSize
        let scale = max(ds.width / image.extent.width, ds.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: (ds.width - image.extent.width) / 2 - image.extent.origin.x,
            y: (ds.height - image.extent.height) / 2 - image.extent.origin.y))

        let dest = CIRenderDestination(width: Int(ds.width), height: Int(ds.height),
                                       pixelFormat: view.colorPixelFormat,
                                       commandBuffer: commandBuffer,
                                       mtlTextureProvider: { drawable.texture })
        _ = try? ciContext.startTask(toRender: image, from: CGRect(origin: .zero, size: ds),
                                     to: dest, at: .zero)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct MetalPreview: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false          // wajib supaya Core Image bisa menulis ke drawable
        v.preferredFramesPerSecond = 30
        v.delegate = renderer
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
