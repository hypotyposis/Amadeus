import AppKit
import CoreVideo
import MetalKit

struct MovieFrame {
    let textures: [MTLTexture]
    // Preserve the IOSurfaces and cache bindings until the GPU retires the frame.
    let buffers: DecodedPair
    let bindings: [CVMetalTexture]
    let metadata: VideoMetadata
}

private struct SceneUniforms {
    var canvas: SIMD4<Float> // width, height, scanline phase, alpha
    var sprite: SIMD4<Float> // x, y, width, height in CRT points
    var movie: SIMD4<Float>  // coded UV scale, full range, character visibility
    var bezel: SIMD4<Float>  // center x/y, horizontal/vertical vignette radii
}

final class WallpaperView: NSView, MTKViewDelegate {
    override var isFlipped: Bool { true }
    private let surface: MTKView
    private let maxDensity: Double?
    private var clock: WallpaperFrameClock
    private var vsync: CADisplayLink?
    private let background = CALayer()
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private var artSize = CGSize(width: 1672, height: 941)
    private var points: [CGPoint] = []
    private var polygon: [SIMD2<Float>] = []
    private var crtMask: (texture: MTLTexture, canvasSize: CGSize)?
    private var tube = CGRect.zero
    private var scanlineAlpha: Float = 0.103
    private var captionText = ""
    private var visibleCharacter = true
    var canvasSize: CGSize?
    var frameToDisplay: MovieFrame?
    var onTick: (() -> Void)?
    var onFirstPresentation: (() -> Void)?
    private let reportCadence = ProcessInfo.processInfo.environment["AMADEUS_NATIVE_WALLPAPER_STATS"] == "1"
    private var cadenceStart: Double?
    private var cadenceFrames = 0
    private var sceneTime = 0.0
    private var lastTime: Double?

    init(device: MTLDevice, fps: Int, maxDensity: Double?) throws {
        self.maxDensity = maxDensity
        clock = WallpaperFrameClock(fps: fps)
        guard let commands = device.makeCommandQueue() else { throw WallpaperFailure("Metal command queue unavailable") }
        self.commands = commands
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "viewport")
        descriptor.fragmentFunction = library.makeFunction(name: "crt")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "crtMask")
        descriptor.colorAttachments[0].pixelFormat = .r8Uint
        maskPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw WallpaperFailure("Metal video texture cache unavailable (\(status))") }
        textureCache = cache
        surface = MTKView(frame: .zero, device: device)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 5/255, green: 7/255, blue: 11/255, alpha: 1).cgColor
        background.contentsGravity = .resizeAspectFill
        layer?.addSublayer(background)

        surface.autoResizeDrawable = false
        surface.colorPixelFormat = .bgra8Unorm
        surface.clearColor = MTLClearColorMake(0, 0, 0, 0)
        surface.wantsLayer = true
        surface.layer?.isOpaque = false
        surface.delegate = self
        surface.isPaused = true
        addSubview(surface)

        caption.alignment = .center
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byTruncatingTail
        caption.textColor = NSColor(srgbRed: 0.88, green: 1, blue: 1, alpha: 1)
        caption.wantsLayer = true
        caption.layer?.backgroundColor = NSColor(srgbRed: 0.02, green: 0.09, blue: 0.11, alpha: 0.88).cgColor
        caption.layer?.cornerRadius = 6
        caption.isHidden = true
        addSubview(caption)
    }

    required init?(coder: NSCoder) { nil }

    func configure(image: NSImage, artwork: CGSize, crt: [CGPoint], scanline: Float) {
        artSize = artwork
        points = crt
        scanlineAlpha = min(0.3, max(0, scanline / 255)) * 0.82
        background.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setPaused(_ value: Bool) {
        lastTime = nil
        clock.reset()
        cadenceStart = nil
        cadenceFrames = 0
        if !value && vsync == nil {
            let link = displayLink(target: self, selector: #selector(onVSync(_:)))
            vsync = link
            configureDisplayLink()
            link.add(to: .main, forMode: .common)
        }
        vsync?.isPaused = value
    }

    @objc private func onVSync(_ link: CADisplayLink) {
        let interval = link.targetTimestamp - link.timestamp
        if clock.shouldPresent(at: link.timestamp, refreshPeriod: interval) { surface.draw() }
    }

    private func configureDisplayLink() {
        guard let screen = window?.screen else { return }
        let refresh = Float(screen.maximumFramesPerSecond)
        vsync?.preferredFrameRateRange = CAFrameRateRange(minimum: refresh, maximum: refresh, preferred: refresh)
    }

    func setCharacterVisible(_ value: Bool) {
        visibleCharacter = value
        caption.isHidden = !value || captionText.isEmpty
    }

    func setCaption(_ text: String) {
        captionText = text
        caption.stringValue = text
        caption.isHidden = !visibleCharacter || text.isEmpty
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        CATransaction.commit()
        guard !points.isEmpty else { return }
        let scale = max(bounds.width / artSize.width, bounds.height / artSize.height)
        let x = (bounds.width - artSize.width * scale) / 2
        let y = (bounds.height - artSize.height * scale) / 2
        let positions = points.map { CGPoint(x: $0.x * scale + x, y: $0.y * scale + y) }
        let left = positions.map(\.x).min()!, right = positions.map(\.x).max()!
        let top = positions.map(\.y).min()!, bottom = positions.map(\.y).max()!
        tube = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let canvas = CGRect(x: floor(left), y: floor(top), width: ceil(right) - floor(left),
                            height: ceil(bottom + tube.height * 0.043) - floor(top)).intersection(bounds)
        guard canvas.width > 0, canvas.height > 0 else { return }
        surface.frame = canvas
        resizeDrawable()
        let nextPolygon = positions.map { SIMD2(Float($0.x - canvas.minX), Float($0.y - canvas.minY)) }
        if nextPolygon != polygon {
            polygon = nextPolygon
            crtMask = nil
        }
        let captionWidth = min(tube.width * 0.72, tube.width - 24)
        let captionHeight = max(34, min(captionWidth / 5.96, tube.height * 0.16))
        caption.frame = CGRect(x: tube.midX - captionWidth / 2, y: tube.maxY - captionHeight,
                               width: captionWidth, height: captionHeight)
        caption.font = .systemFont(ofSize: min(17, max(11, round(captionWidth / 34))))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
        configureDisplayLink()
    }

    private func resizeDrawable() {
        let scale = min(window?.backingScaleFactor ?? 1, maxDensity ?? .infinity)
        surface.drawableSize = CGSize(width: max(1, (surface.bounds.width * scale).rounded()),
                                      height: max(1, (surface.bounds.height * scale).rounded()))
    }

    func textures(for pair: DecodedPair, metadata: VideoMetadata) throws -> MovieFrame {
        let inputs: [(CVPixelBuffer, Int, MTLPixelFormat)] = [
            (pair.color, 0, .r8Unorm), (pair.color, 1, .rg8Unorm), (pair.alpha, 0, .r8Unorm),
        ]
        var textures: [MTLTexture] = []
        var bindings: [CVMetalTexture] = []
        for (buffer, plane, format) in inputs {
            var binding: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
                CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &binding)
            guard status == kCVReturnSuccess, let binding, let texture = CVMetalTextureGetTexture(binding) else {
                throw WallpaperFailure("Unable to bind decoded VP9 surface to Metal (\(status))")
            }
            textures.append(texture)
            bindings.append(binding)
        }
        return MovieFrame(textures: textures, buffers: pair, bindings: bindings, metadata: metadata)
    }

    private func mask(for canvas: CGSize, matching drawable: MTLTexture, in command: MTLCommandBuffer) -> MTLTexture? {
        if let crtMask, crtMask.canvasSize == canvas,
           crtMask.texture.width == drawable.width, crtMask.texture.height == drawable.height {
            return crtMask.texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint, width: drawable.width, height: drawable.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = commands.device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let draw = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var size = SIMD2(Float(canvas.width), Float(canvas.height))
        var pointCount = UInt32(polygon.count)
        draw.setRenderPipelineState(maskPipeline)
        draw.setFragmentBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        polygon.withUnsafeBufferPointer {
            draw.setFragmentBytes($0.baseAddress!, length: $0.count * MemoryLayout<SIMD2<Float>>.stride, index: 1)
        }
        draw.setFragmentBytes(&pointCount, length: MemoryLayout<UInt32>.size, index: 2)
        draw.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        draw.endEncoding()
        return texture
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        if let lastTime { sceneTime += min(now - lastTime, 0.05) }
        lastTime = now
        onTick?()
        let frameRect = surface.frame
        guard let frame = frameToDisplay, polygon.count >= 3, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor, let command = commands.makeCommandBuffer(),
              let mask = mask(for: frameRect.size, matching: drawable.texture, in: command),
              let draw = command.makeRenderCommandEncoder(descriptor: pass) else { return }

        let layout = frame.metadata.layout
        let fit = canvasSize ?? CGSize(width: layout.width, height: layout.height)
        let scale = min(tube.width * 0.64 / fit.width, tube.height * 0.90 / fit.height)
        let spriteWidth = Double(layout.width) * scale
        let spriteHeight = Double(layout.height) * scale
        let centering = tube.minX + tube.width * 0.52 - frameRect.minX
        let foot = tube.maxY - max(3, tube.height * 0.012) - frameRect.minY
        var uniforms = SceneUniforms(
            canvas: SIMD4(Float(frameRect.width), Float(frameRect.height),
                          Float((sceneTime * 14).truncatingRemainder(dividingBy: 3)), scanlineAlpha),
            sprite: SIMD4(Float(centering - spriteWidth / 2), Float(foot - spriteHeight),
                          Float(spriteWidth), Float(spriteHeight)),
            movie: SIMD4(Float(layout.width) / Float(layout.codedWidth), Float(layout.height) / Float(layout.codedHeight),
                         frame.metadata.streams.color.colorSpace.fullRange ? 1 : 0,
                         visibleCharacter ? 1 : 0),
            bezel: SIMD4(Float(centering), Float(tube.maxY - frameRect.minY),
                         Float(tube.width * 0.38), Float(tube.height * 0.0425)))
        draw.setRenderPipelineState(pipeline)
        draw.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        for (index, texture) in frame.textures.enumerated() { draw.setFragmentTexture(texture, index: index) }
        draw.setFragmentTexture(mask, index: 3)
        draw.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        draw.endEncoding()
        command.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
        if let first = onFirstPresentation {
            onFirstPresentation = nil
            drawable.addPresentedHandler { _ in DispatchQueue.main.async(execute: first) }
        }
        command.present(drawable)
        // Publish only when the command that initializes the mask is committed.
        if crtMask?.texture !== mask { crtMask = (mask, frameRect.size) }
        command.commit()
        if reportCadence {
            if cadenceStart == nil { cadenceStart = now }
            cadenceFrames += 1
            if let start = cadenceStart, now - start >= 10 {
                let fps = Double(cadenceFrames - 1) / (now - start)
                print("[native-wallpaper] \(String(format: "%.2f", fps)) FPS, drawable \(Int(view.drawableSize.width))×\(Int(view.drawableSize.height))")
                fflush(stdout)
                cadenceStart = now
                cadenceFrames = 1
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Scene { float4 canvas; float4 sprite; float4 movie; float4 bezel; };
    vertex Vertex viewport(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
    }
    float4 over(float4 source, float4 destination) {
        return source + destination * (1 - source.a);
    }
    fragment uint crtMask(Vertex v [[stage_in]], constant float2 &canvas [[buffer(0)]],
                          constant float2 *polygon [[buffer(1)]], constant uint &pointCount [[buffer(2)]]) {
        float2 p = v.uv * canvas;
        bool inside = false;
        int count = int(pointCount);
        for (int i=0,j=count-1; i<count; j=i++) {
            float2 a = polygon[i], b = polygon[j];
            if ((a.y > p.y) != (b.y > p.y) && p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x) inside = !inside;
        }
        return inside ? 1u : 0u;
    }
    fragment float4 crt(Vertex v [[stage_in]], constant Scene &s [[buffer(0)]],
                        texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]],
                        texture2d<float> alpha [[texture(2)]], texture2d<uint, access::read> mask [[texture(3)]]) {
        float2 p = v.uv * s.canvas.xy;
        float4 out = float4(0);
        if (mask.read(uint2(v.position.xy)).r != 0) {
            float2 q = (p - s.sprite.xy) / s.sprite.zw;
            if (s.movie.w > 0 && all(q >= 0) && all(q < 1)) {
                constexpr sampler sample(filter::linear, address::clamp_to_edge);
                float2 uv = q * s.movie.xy;
                float y = luma.sample(sample, uv).r;
                float2 c = chroma.sample(sample, uv).rg - 128.0/255.0;
                if (s.movie.z < 0.5) { y = (y - 16.0/255.0) * (255.0/219.0); c *= 255.0/224.0; }
                float3 rgb = saturate(float3(y + 1.5748*c.y, y - 0.1873*c.x - 0.4681*c.y, y + 1.8556*c.x));
                rgb = mix(float3(dot(rgb, float3(0.2126,0.7152,0.0722))), rgb, 0.9) * 0.95;
                float a = alpha.sample(sample, uv).r;
                out = float4(rgb*a, a);
            }
            out = over(float4(float3(7.0,18.0,28.0)/255.0*0.10, 0.10), out);
            float dist = abs(fract((p.y - s.canvas.z + 1.5) / 3.0) * 3.0 - 1.5);
            float edge = fwidth(p.y)*0.5;
            out = over(float4(0,0,0,s.canvas.w*(1-smoothstep(0.5-edge,0.5+edge,dist))), out);
        }
        float radius = length((p - s.bezel.xy) / s.bezel.zw);
        float vignette = max(0.0, 1.0-radius) * 0.62;
        return over(float4(0,0,0,vignette), out);
    }
    """
}
