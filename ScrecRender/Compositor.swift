import CoreGraphics
import CoreVideo
import Foundation
import ScrecCore
import Metal
import MetalKit
import MetalPerformanceShaders

/// The one deterministic compositor used by preview and export (ARCHITECTURE §1, §9).
///
/// `render` draws the frame at timeline time `t` from `PreparedProject` (look, layout, motion tracks) and
/// the source frame for that time. Same inputs → same pixels: no wall clock, no randomness, no state that
/// carries over from the previous frame (the caches below only hold textures, never results).
public final class Compositor {
    public enum CompositorError: Error, CustomStringConvertible {
        case noLibrary, pipeline(String), textureCache
        public var description: String {
            switch self {
            case .noLibrary: "The compositor shaders could not be loaded."
            case let .pipeline(name): "The \(name) render pipeline could not be created."
            case .textureCache: "The video texture cache could not be created."
            }
        }
    }

    public let device: MTLDevice
    private let library: MTLLibrary
    private let backgroundPipeline: MTLRenderPipelineState
    private let scenePipeline: MTLRenderPipelineState
    private let sourcePipeline: MTLRenderPipelineState
    private var cameraPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var webcamPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var overlayPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var badgeTextures: [String: MTLTexture] = [:]
    private var captionTextures: [String: MTLTexture] = [:]
    private let sampler: MTLSamplerState
    private let textureCache: CVMetalTextureCache
    private let textureLoader: MTKTextureLoader

    private var cursorTextures: [String: (texture: MTLTexture, hotspot: CGPoint)] = [:]
    private var backgroundImage: (url: URL, texture: MTLTexture)?
    private var targets: [String: MTLTexture] = [:]
    private let blank: MTLTexture
    private let blankChroma: MTLTexture

    /// Cursor art height in screen points for size 1× (the real macOS arrow is about this tall).
    public static let cursorPoints = 28.0
    /// Click effect radius in screen points for size 1×.
    public static let clickRadiusPoints = 16.0
    /// How long a click effect lasts.
    public static let clickDuration = 0.45

    public init(device: MTLDevice) throws {
        self.device = device
        self.library = try Self.loadLibrary(device)
        backgroundPipeline = try Self.pipeline(device, library, fragment: "backgroundFragment", format: .rgba16Float)
        scenePipeline = try Self.pipeline(device, library, fragment: "sceneFragment", format: .rgba16Float)
        sourcePipeline = try Self.pipeline(device, library, fragment: "sourceRGBFragment", format: .rgba16Float)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw CompositorError.pipeline("sampler") }
        self.sampler = sampler

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { throw CompositorError.textureCache }
        textureCache = cache
        textureLoader = MTKTextureLoader(device: device)

        blank = Self.solidTexture(device, format: .r8Unorm, bytes: [16])
        blankChroma = Self.solidTexture(device, format: .rg8Unorm, bytes: [128, 128])
    }

    /// Compiles `Compositor.msl` (Metal shader source) from the framework's resources.
    private static func loadLibrary(_ device: MTLDevice) throws -> MTLLibrary {
        guard let url = Bundle(for: Compositor.self).url(forResource: "Compositor", withExtension: "msl"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw CompositorError.noLibrary }
        let options = MTLCompileOptions()
        options.mathMode = .safe          // identical results for preview and export
        do {
            return try device.makeLibrary(source: source, options: options)
        } catch {
            NSLog("Screc: shader compile error: \(error)")
            throw CompositorError.noLibrary
        }
    }

    // MARK: Render

    public struct Frame {
        /// Timeline time.
        public var t: Double
        /// 1 / output frame rate; sets the motion-blur shutter.
        public var frameInterval: Double
        /// The source frame for `t` (4:2:0 video range, as recorded), or nil to draw without the recording.
        public var source: CVPixelBuffer?
        /// Folder of the `.screc` bundle (for a background image).
        public var bundle: URL?
        /// The webcam frame for `t` (BGRA), if the recording has a camera.
        public var camera: CVPixelBuffer?

        public init(t: Double, frameInterval: Double, source: CVPixelBuffer?, bundle: URL?, camera: CVPixelBuffer? = nil) {
            self.t = t
            self.frameInterval = frameInterval
            self.source = source
            self.bundle = bundle
            self.camera = camera
        }
    }

    public func render(_ p: PreparedProject, frame: Frame, into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        var look = p.project.look
        // Per-slice cursor settings (ED-05) replace the project's for the slice playing now.
        if let i = p.timeMap.entryIndex(atTimeline: frame.t),
           let slice = p.project.timeline.slices.first(where: { $0.id == p.timeMap.entries[i].sliceID }),
           let override = slice.cursorOverride {
            look.cursor = override.applied(to: look.cursor)
        }
        let outSize = CGSize(width: target.width, height: target.height)
        let ref = Layout.referenceScale(outputSize: outSize)

        // Motion blur: M samples of the camera and cursor across the shutter (100 = half a frame interval).
        let blur = min(max(look.animation.motionBlur, 0), 100) / 100
        let shutter = blur * 0.5 * frame.frameInterval
        let taps = blur > 0 ? 8 : 1
        let times = (0..<taps).map { k in taps == 1 ? frame.t : frame.t + shutter * (Double(k) / Double(taps - 1) - 0.5) }
        let cameras = times.map { p.adjusted(p.camera.state(at: $0), at: frame.t) }
        // Camera layouts can move the screen (split screen).
        let frameLayout = p.effectiveLayout(at: frame.t)

        // Scene resolution: enough to stay sharp at the current zoom, but never more detail than the source has.
        let zMax = cameras.map(\.scale).max() ?? 1
        let density = max(p.layout.sourceDensity(outputSize: outSize), 1)
        let sceneScale = min(max(min(zMax, density), 1), 3)
        let sceneW = min(Int((Double(outSize.width) * sceneScale).rounded()), 8192)
        let sceneH = min(Int((Double(outSize.height) * sceneScale).rounded()), 8192)
        let sceneSize = CGSize(width: sceneW, height: sceneH)
        let short = Double(min(sceneW, sceneH))
        let sceneRef = ref * Double(sceneW) / Double(outSize.width)

        // 1. Background (optionally blurred).
        let bg = texture("bg", sceneW, sceneH, .rgba16Float, usage: [.renderTarget, .shaderRead, .shaderWrite])
        var bgUniforms = try backgroundUniforms(look.background, aspect: p.layout.canvasAspect, bundle: frame.bundle)
        try pass(commandBuffer, into: bg, pipeline: backgroundPipeline) { enc in
            enc.setFragmentBytes(&bgUniforms, length: MemoryLayout<BackgroundUniforms>.stride, index: 0)
            enc.setFragmentTexture(backgroundImage?.texture ?? blank, index: 0)
        }
        var background = bg
        if look.background.blur > 0 {
            let blurred = texture("bgBlur", sceneW, sceneH, .rgba16Float, usage: [.renderTarget, .shaderRead, .shaderWrite])
            let sigma = Float(look.background.blur / 100 * 0.04 * short)
            MPSImageGaussianBlur(device: device, sigma: max(sigma, 0.1)).encode(commandBuffer: commandBuffer, sourceTexture: bg, destinationTexture: blurred)
            background = blurred
        }

        // 2. Source frame textures (Y and CbCr planes, no copy).
        var luma: CVMetalTexture?, chroma: CVMetalTexture?
        if let pb = frame.source, CVPixelBufferGetPlaneCount(pb) == 2 {
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil, .r8Unorm,
                                                      CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &luma)
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil, .rg8Unorm,
                                                      CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1), 1, &chroma)
        }
        let lumaTex = luma.flatMap(CVMetalTextureGetTexture)
        let chromaTex = chroma.flatMap(CVMetalTextureGetTexture)

        // Masks active at this moment (their time range is in source time).
        let sourceNow = p.timeMap.toSource(frame.t)
        let activeMasks = p.project.masks.filter { $0.sourceStart <= sourceNow && sourceNow < $0.sourceEnd && $0.rect.count == 4 }.prefix(8)
        var maskData: [SIMD4<Float>] = []
        for m in activeMasks {
            let kind: Float = switch m.kind { case .blur: 0; case .hide: 1; case .highlight: 2 }
            maskData.append(SIMD4(Float(m.rect[0]), Float(m.rect[1]), Float(m.rect[2]), Float(m.rect[3])))
            maskData.append(SIMD4(kind, Float(min(max(m.strength, 0), 1)), 0, 0))
        }
        // Blur masks need a blurred copy of the recording (half resolution is plenty).
        var blurredSource: MTLTexture?
        if let lumaTex, let chromaTex, let strongest = activeMasks.filter({ $0.kind == .blur }).map(\.strength).max() {
            let w = max(lumaTex.width / 2, 2), h = max(lumaTex.height / 2, 2)
            let rgb = texture("srcRGB", w, h, .rgba16Float, usage: [.renderTarget, .shaderRead])
            try pass(commandBuffer, into: rgb, pipeline: sourcePipeline) { enc in
                enc.setFragmentTexture(lumaTex, index: 0)
                enc.setFragmentTexture(chromaTex, index: 1)
            }
            let blurred = texture("srcBlur", w, h, .rgba16Float, usage: [.shaderRead, .shaderWrite])
            let sigma = Float(max(min(max(strongest, 0), 1), 0.1) * 0.025 * Double(min(w, h)))
            MPSImageGaussianBlur(device: device, sigma: sigma).encode(commandBuffer: commandBuffer, sourceTexture: rgb, destinationTexture: blurred)
            blurredSource = blurred
        }
        if maskData.isEmpty { maskData = [.zero, .zero] }

        // 3. Scene.
        let screenPx = CGRect(x: frameLayout.screenRect.minX * sceneSize.width, y: frameLayout.screenRect.minY * sceneSize.height,
                              width: frameLayout.screenRect.width * sceneSize.width, height: frameLayout.screenRect.height * sceneSize.height)
        // Recording pixels → scene pixels.
        let recToScene = Double(screenPx.height) / (Double(p.layout.recordingSize.height) * Double(p.layout.crop.height))
        func scenePoint(_ x: Double, _ y: Double) -> SIMD2<Float> {
            let c = frameLayout.canvasPoint(fromRecordingPixels: CGPoint(x: x, y: y))
            return SIMD2(Float(c.x * sceneSize.width), Float(c.y * sceneSize.height))
        }

        var u = SceneUniforms()
        u.sceneSize = SIMD4(Float(sceneW), Float(sceneH), 0, 0)
        u.screenRect = SIMD4(Float(screenPx.minX), Float(screenPx.minY), Float(screenPx.width), Float(screenPx.height))
        u.crop = SIMD4(Float(p.layout.crop.minX), Float(p.layout.crop.minY), Float(p.layout.crop.width), Float(p.layout.crop.height))
        u.corner = SIMD4(Float(look.frame.cornerRadius * sceneRef), Float(1 * sceneRef), look.frame.inset ? 1 : 0, lumaTex != nil ? 1 : 0)
        u.shadow = shadowUniform(look.frame.shadow, short: short)

        // Cursor.
        var cursorTaps: [SIMD4<Float>] = []
        let cursorSample = p.cursor.sample(at: frame.t)
        if p.hasCursorData, !look.cursor.hidden, cursorSample.opacity > 0.001 {
            let pixelHeight = Self.cursorPoints * p.pointPixelScale * look.cursor.size * recToScene
            if let art = cursorTexture(style: look.cursor.style, shape: cursorSample.shape, color: look.cursor.color, pixelHeight: pixelHeight) {
                for t in times {
                    let c = p.cursor.sample(at: t)
                    let sp = scenePoint(c.x, c.y)
                    cursorTaps.append(SIMD4(sp.x, sp.y, Float(c.angle * .pi / 180), 0))
                }
                u.cursorSprite = SIMD4(Float(art.texture.width), Float(art.texture.height), Float(art.hotspot.x), Float(art.hotspot.y))
                u.cursorInfo = SIMD4(Float(cursorSample.opacity), Float(cursorTaps.count), 1, 0)
                cursorTextureInUse = art.texture
            }
        }
        if cursorTaps.isEmpty { cursorTaps = [.zero] }

        // Click effects.
        var clicks: [SIMD4<Float>] = []
        if look.cursor.clickEffect != .none, p.hasCursorData {
            for c in p.cursor.clicks.reversed() where c.t <= frame.t && frame.t < c.t + Self.clickDuration {
                let sp = scenePoint(c.x, c.y)
                clicks.append(SIMD4(sp.x, sp.y, Float((frame.t - c.t) / Self.clickDuration), 0))
                if clicks.count == 8 { break }
            }
            let radius = Self.clickRadiusPoints * p.pointPixelScale * look.cursor.size * recToScene
            u.clickInfo = SIMD4(Float(clicks.count), Float(radius), look.cursor.clickEffect == .circle ? 1 : 2, 0)
        }
        if clicks.isEmpty { clicks = [.zero] }
        u.maskInfo = SIMD4(Float(activeMasks.count), activeMasks.contains { $0.kind == .highlight } ? 1 : 0, 0, 0)

        let scene = texture("scene", sceneW, sceneH, .rgba16Float, usage: [.renderTarget, .shaderRead])
        let cursorTex = cursorTextureInUse ?? blank
        try pass(commandBuffer, into: scene, pipeline: scenePipeline) { enc in
            enc.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            enc.setFragmentBytes(cursorTaps, length: MemoryLayout<SIMD4<Float>>.stride * cursorTaps.count, index: 1)
            enc.setFragmentBytes(clicks, length: MemoryLayout<SIMD4<Float>>.stride * clicks.count, index: 2)
            enc.setFragmentBytes(maskData, length: MemoryLayout<SIMD4<Float>>.stride * maskData.count, index: 3)
            enc.setFragmentTexture(background, index: 0)
            enc.setFragmentTexture(lumaTex ?? blank, index: 1)
            enc.setFragmentTexture(chromaTex ?? blankChroma, index: 2)
            enc.setFragmentTexture(cursorTex, index: 3)
            enc.setFragmentTexture(blurredSource ?? blank, index: 4)
        }
        cursorTextureInUse = nil

        // 4. Camera: zoom the whole composition (the background zooms too), averaged over the shutter.
        let cameraTaps = cameras.map { SIMD4(Float($0.scale), Float($0.center.x), Float($0.center.y), 0) }
        var cu = CameraUniforms(info: SIMD4(Float(cameraTaps.count), Float(Double(sceneW) / Double(outSize.width)),
                                            Float(outSize.width), Float(outSize.height)))
        try pass(commandBuffer, into: target, pipeline: try cameraPipeline(for: target.pixelFormat)) { enc in
            enc.setFragmentBytes(&cu, length: MemoryLayout<CameraUniforms>.stride, index: 0)
            enc.setFragmentBytes(cameraTaps, length: MemoryLayout<SIMD4<Float>>.stride * cameraTaps.count, index: 1)
            enc.setFragmentTexture(scene, index: 0)
        }

        // 5. Overlays on top of the camera (they never zoom): the webcam, captions, then the keyboard-shortcut badge.
        let webcam = p.layouts.state(at: frame.t)
        if webcam.opacity > 0.001, webcam.webcam.width > 0, let cam = frame.camera {
            var camTex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, cam, nil, .bgra8Unorm_srgb,
                                                      CVPixelBufferGetWidth(cam), CVPixelBufferGetHeight(cam), 0, &camTex)
            if let camTex, let tex = CVMetalTextureGetTexture(camTex) {
                let r = webcam.webcam
                let rect = CGRect(x: r.minX * Double(outSize.width), y: r.minY * Double(outSize.height),
                                  width: r.width * Double(outSize.width), height: r.height * Double(outSize.height))
                let fullCanvas = r.width >= 0.999 && r.height >= 0.999
                var wu = WebcamUniforms(rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                                        info: SIMD4(Float(webcam.opacity), Float(webcam.radius * Double(min(rect.width, rect.height))),
                                                    p.project.look.webcam.mirror ? 1 : 0, p.project.look.webcam.shadow && !fullCanvas ? 1 : 0),
                                        sizes: SIMD4(Float(outSize.width), Float(outSize.height), Float(tex.width), Float(tex.height)))
                try pass(commandBuffer, into: target, pipeline: try webcamPipeline(for: target.pixelFormat), load: true) { enc in
                    enc.setFragmentBytes(&wu, length: MemoryLayout<WebcamUniforms>.stride, index: 0)
                    enc.setFragmentTexture(tex, index: 0)
                }
            }
        }
        let outShortSide = Double(min(outSize.width, outSize.height))
        var captionRect: CGRect?     // so the key badge can move out of its way
        if look.captions.enabled, let active = p.captions.active(at: frame.t) {
            let c = look.captions
            let textHeight = Int((c.size.fraction * outShortSide).rounded())
            let maxWidth = Int(Double(outSize.width) * 0.8)
            let words = active.line.words.map(\.text)
            let key = "\(active.lineIndex)|\(c.style == .highlight ? active.wordIndex ?? -1 : -1)|\(c.style.rawValue)|\(textHeight)|\(maxWidth)|"
                + "\(c.font)|\(c.textColor)|\(c.highlightColor)|\(c.boxColor)|\(c.boxOpacity)|\(words.joined(separator: " "))"
            if let tex = captionTexture(key: key, words: words, activeWord: active.wordIndex, look: c, textHeight: textHeight, maxWidth: maxWidth) {
                let w = Double(tex.width), h = Double(tex.height)
                let o = c.origin(box: CGSize(width: w, height: h), output: CGSize(width: outSize.width, height: outSize.height))
                let x = Double(o.x), y = Double(o.y)
                captionRect = CGRect(x: x, y: y, width: w, height: h)
                var ou = OverlayUniforms(rect: SIMD4(Float(x.rounded()), Float(y.rounded()), Float(w), Float(h)),
                                         info: SIMD4(1, Float(outSize.width), Float(outSize.height), 0))
                try pass(commandBuffer, into: target, pipeline: try overlayPipeline(for: target.pixelFormat), load: true) { enc in
                    enc.setFragmentBytes(&ou, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
                    enc.setFragmentTexture(tex, index: 0)
                }
            }
        }
        if look.keys.enabled, let (item, opacity) = p.keys.active(at: frame.t), opacity > 0.001 {
            let outShort = Double(min(outSize.width, outSize.height))
            let keyHeight = Int((look.keys.size.heightFraction * outShort).rounded())
            if let badge = badgeTexture(tokens: item.tokens, repeatCount: item.repeatCount, keyHeight: keyHeight) {
                let w = Double(badge.width), h = Double(badge.height)
                let margin = 0.06 * outShort
                let x = (Double(outSize.width) - w) / 2
                var y = look.keys.position == .bottom ? Double(outSize.height) - margin - h : margin
                if let captionRect, captionRect.intersects(CGRect(x: x, y: y, width: w, height: h).insetBy(dx: 0, dy: -0.02 * outShort)) {
                    y = look.keys.position == .bottom ? captionRect.minY - 0.02 * outShort - h : captionRect.maxY + 0.02 * outShort
                }
                var ou = OverlayUniforms(rect: SIMD4(Float(x.rounded()), Float(y.rounded()), Float(w), Float(h)),
                                         info: SIMD4(Float(opacity), Float(outSize.width), Float(outSize.height), 0))
                try pass(commandBuffer, into: target, pipeline: try overlayPipeline(for: target.pixelFormat), load: true) { enc in
                    enc.setFragmentBytes(&ou, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
                    enc.setFragmentTexture(badge, index: 0)
                }
            }
        }

        // Keep the video plane textures alive until the GPU is done with them.
        // (CVMetalTexture is a thread-safe CF object; it is only retained here, never used.)
        nonisolated(unsafe) let keep = (luma, chroma)
        commandBuffer.addCompletedHandler { _ in _ = keep }
    }

    private var cursorTextureInUse: MTLTexture?

    // MARK: Uniform helpers

    private func shadowUniform(_ s: FrameStyle.Shadow, short: Double) -> SIMD4<Float> {
        let amount = min(max(s.amount, 0), 1)
        guard amount > 0 else { return .zero }
        switch s.style {
        case .classic:
            // Soft, centred, slightly downward.
            return SIMD4(0, Float(0.012 * short), Float(0.035 * short), Float(0.55 * amount))
        case .directional:
            let a = s.angle * .pi / 180
            let dist = min(max(s.distance, 0), 1) * 0.06 * short
            let sigma = (0.004 + min(max(s.softness, 0), 1) * 0.06) * short
            return SIMD4(Float(cos(a) * dist), Float(sin(a) * dist), Float(sigma), Float(0.6 * amount))
        }
    }

    private func backgroundUniforms(_ b: Background, aspect: Double, bundle: URL?) throws -> BackgroundUniforms {
        var u = BackgroundUniforms()
        func lin(_ hex: String) -> SIMD4<Float> {
            let c = ColorParsing.linear(hex)
            return SIMD4(Float(c.r), Float(c.g), Float(c.b), 1)
        }
        switch b.kind {
        case .wallpaper:
            let w = Wallpapers.wallpaper(id: b.wallpaper)
            u.info = SIMD4(0, Float(aspect), Float(w.warp), Float(w.seed))
            for (i, pt) in w.points.prefix(4).enumerated() {
                u.setPoint(i, SIMD4(Float(pt.x), Float(pt.y), 0, 0))
                u.setColor(i, lin(pt.color))
            }
        case .gradient:
            u.info = SIMD4(b.gradient.type == .linear ? 1 : 2, Float(aspect), 0, 0)
            let stops = Array(b.gradient.stops.sorted { $0.location < $1.location }.prefix(4))
            for (i, s) in stops.enumerated() {
                u.setPoint(i, SIMD4(Float(s.location), 0, 0, 0))
                u.setColor(i, lin(s.color))
            }
            u.gradient = SIMD4(Float(max(stops.count, 1)), Float(b.gradient.angle * .pi / 180), 0, 0)
        case .color:
            u.info = SIMD4(3, Float(aspect), 0, 0)
            u.setColor(0, lin(b.color))
        case .image:
            if let name = b.image, let bundle, let tex = try loadBackgroundImage(bundle.appendingPathComponent(name)) {
                u.info = SIMD4(4, Float(aspect), 0, 0)
                u.gradient = SIMD4(0, 0, Float(Double(tex.width) / Double(max(tex.height, 1))), 0)
            } else {
                u.info = SIMD4(3, Float(aspect), 0, 0)
                u.setColor(0, lin(b.color))
            }
        }
        return u
    }

    private func loadBackgroundImage(_ url: URL) throws -> MTLTexture? {
        if let backgroundImage, backgroundImage.url == url { return backgroundImage.texture }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let tex = try textureLoader.newTexture(URL: url, options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft])
        backgroundImage = (url, tex)
        return tex
    }

    private func cursorTexture(style: CursorLook.Style, shape: CursorShape, color: String, pixelHeight: Double) -> (texture: MTLTexture, hotspot: CGPoint)? {
        // Size buckets of 2 px keep the cache small while staying pixel-exact.
        let bucket = max(Int((pixelHeight / 2).rounded()) * 2, 6)
        let key = "\(style.rawValue)|\(shape.rawValue)|\(color)|\(bucket)"
        if let cached = cursorTextures[key] { return cached }
        guard let raster = CursorArt.raster(style: style, shape: shape, colorHex: color, pixelHeight: bucket),
              let tex = try? textureLoader.newTexture(cgImage: raster.image, options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft])
        else { return nil }
        if cursorTextures.count > 64 { cursorTextures.removeAll() }
        cursorTextures[key] = (tex, raster.hotspot)
        return (tex, raster.hotspot)
    }

    // MARK: Metal helpers

    private func texture(_ name: String, _ w: Int, _ h: Int, _ format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture {
        let key = "\(name)-\(w)x\(h)"
        if let t = targets[key] { return t }
        targets = targets.filter { !$0.key.hasPrefix(name + "-") }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        targets[key] = t
        return t
    }

    private func pass(_ cb: MTLCommandBuffer, into target: MTLTexture, pipeline: MTLRenderPipelineState, load: Bool = false,
                      setup: (MTLRenderCommandEncoder) -> Void) throws {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = load ? .load : .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { throw CompositorError.pipeline("encoder") }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        setup(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func cameraPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = cameraPipelines[format] { return p }
        let p = try Self.pipeline(device, library, fragment: "cameraFragment", format: format)
        cameraPipelines[format] = p
        return p
    }

    private func webcamPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = webcamPipelines[format] { return p }
        let p = try Self.pipeline(device, library, fragment: "webcamFragment", format: format, blending: true)
        webcamPipelines[format] = p
        return p
    }

    private func overlayPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = overlayPipelines[format] { return p }
        let p = try Self.pipeline(device, library, fragment: "overlayFragment", format: format, blending: true)
        overlayPipelines[format] = p
        return p
    }

    private func captionTexture(key: String, words: [String], activeWord: Int?, look: CaptionLook, textHeight: Int, maxWidth: Int) -> MTLTexture? {
        if let t = captionTextures[key] { return t }
        guard let image = CaptionArt.raster(words: words, activeWord: activeWord, look: look, textHeight: textHeight, maxWidth: maxWidth),
              let t = try? textureLoader.newTexture(cgImage: image, options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft])
        else { return nil }
        if captionTextures.count > 128 { captionTextures.removeAll() }
        captionTextures[key] = t
        return t
    }

    private func badgeTexture(tokens: [String], repeatCount: Int, keyHeight: Int) -> MTLTexture? {
        let key = tokens.joined(separator: "\u{1}") + "|\(repeatCount)|\(keyHeight)"
        if let t = badgeTextures[key] { return t }
        guard let image = KeyBadgeArt.raster(tokens: tokens, repeatCount: repeatCount, keyHeight: keyHeight),
              let t = try? textureLoader.newTexture(cgImage: image, options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft])
        else { return nil }
        if badgeTextures.count > 64 { badgeTextures.removeAll() }
        badgeTextures[key] = t
        return t
    }

    private static func pipeline(_ device: MTLDevice, _ library: MTLLibrary, fragment: String, format: MTLPixelFormat,
                                 blending: Bool = false) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = format
        if blending {
            // Premultiplied "over".
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            return try device.makeRenderPipelineState(descriptor: d)
        } catch {
            throw CompositorError.pipeline(fragment)
        }
    }

    private static func solidTexture(_ device: MTLDevice, format: MTLPixelFormat, bytes: [UInt8]) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
        let t = device.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytes.count)
        return t
    }
}

// Mirrors of the Metal structs (all members are float4, so the layouts match without padding surprises).
struct BackgroundUniforms {
    var info = SIMD4<Float>.zero
    var p0 = SIMD4<Float>.zero, p1 = SIMD4<Float>.zero, p2 = SIMD4<Float>.zero, p3 = SIMD4<Float>.zero
    var c0 = SIMD4<Float>.zero, c1 = SIMD4<Float>.zero, c2 = SIMD4<Float>.zero, c3 = SIMD4<Float>.zero
    var gradient = SIMD4<Float>(1, 0, 1, 0)

    mutating func setPoint(_ i: Int, _ v: SIMD4<Float>) {
        switch i {
        case 0: p0 = v
        case 1: p1 = v
        case 2: p2 = v
        default: p3 = v
        }
    }

    mutating func setColor(_ i: Int, _ v: SIMD4<Float>) {
        switch i {
        case 0: c0 = v
        case 1: c1 = v
        case 2: c2 = v
        default: c3 = v
        }
    }
}

struct SceneUniforms {
    var sceneSize = SIMD4<Float>.zero
    var screenRect = SIMD4<Float>.zero
    var crop = SIMD4<Float>(0, 0, 1, 1)
    var corner = SIMD4<Float>.zero
    var shadow = SIMD4<Float>.zero
    var cursorSprite = SIMD4<Float>(1, 1, 0, 0)
    var cursorInfo = SIMD4<Float>.zero
    var clickInfo = SIMD4<Float>.zero
    var maskInfo = SIMD4<Float>.zero
}

struct CameraUniforms {
    var info: SIMD4<Float>
}

struct OverlayUniforms {
    var rect: SIMD4<Float>
    var info: SIMD4<Float>
}

struct WebcamUniforms {
    var rect: SIMD4<Float>
    var info: SIMD4<Float>
    var sizes: SIMD4<Float>
}
