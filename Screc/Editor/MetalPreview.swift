@preconcurrency import AVFoundation
import ScrecCore
import ScrecRender
import MetalKit
import SwiftUI

/// The preview canvas: an `MTKView` that asks the compositor for the frame at the player's current time.
/// It uses the same `Compositor` as export (ARCHITECTURE §9.3); only the output size differs
/// (Full / Half / Quarter quality scales the drawable).
struct MetalPreview: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Renderer { Renderer(model: model) }

    func makeNSView(context: Context) -> QualityMTKView {
        let view = QualityMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm_srgb      // shaders write linear light; the view encodes to sRGB
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Draw at the display's own refresh rate (75 Hz, 120 Hz on ProMotion…). Cursor and camera are computed
        // for the exact moment of every refresh, so this is smoother than 60 fps and avoids 60-on-75 Hz judder.
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        view.quality = model.quality.rawValue
        return view
    }

    func updateNSView(_ view: QualityMTKView, context: Context) {
        view.quality = model.quality.rawValue
    }

    /// Scales the drawable with the preview quality.
    final class QualityMTKView: MTKView {
        var quality: Double = 1 {
            didSet { if quality != oldValue { updateDrawableSize() } }
        }

        override init(frame: CGRect, device: MTLDevice?) {
            super.init(frame: frame, device: device)
            autoResizeDrawable = false
        }

        required init(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            updateDrawableSize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateDrawableSize()
        }

        private func updateDrawableSize() {
            let scale = (window?.backingScaleFactor ?? 2) * quality
            let size = CGSize(width: max((bounds.width * scale).rounded(), 2), height: max((bounds.height * scale).rounded(), 2))
            if drawableSize != size { drawableSize = size }
        }
    }

    @MainActor
    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let compositor: Compositor?
        private let model: EditorModel
        private var lastFrame: CVPixelBuffer?
        private var webcam: CameraFrameReader?

        init(model: EditorModel) {
            self.model = model
            device = MTLCreateSystemDefaultDevice()!
            queue = device.makeCommandQueue()!
            do {
                compositor = try Compositor(device: device)
            } catch {
                compositor = nil
                model.show("\(error)")
            }
            super.init()
            if model.hasCamera {
                let bundle = model.bundle
                Task { @MainActor [weak self] in self?.webcam = await CameraFrameReader.forBundle(bundle) }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let compositor, let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
            let output = model.videoOutput
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                lastFrame = pb
            }
            let t = itemTime.isValid ? min(max(itemTime.seconds, 0), model.duration) : model.currentTime
            // Motion blur shutter as in a 60 fps export, so preview and export look the same.
            do {
                let p = model.displayed
                let cam = p.layouts.hasCamera && p.layouts.state(at: t).opacity > 0.001 ? webcam?.frame(atSource: p.timeMap.toSource(t)) : nil
                try compositor.render(p, frame: .init(t: t, frameInterval: 1 / 60, source: lastFrame, bundle: model.bundle, camera: cam),
                                      into: drawable.texture, commandBuffer: cb)
            } catch {
                return
            }
            cb.present(drawable)
            cb.commit()
        }
    }
}
