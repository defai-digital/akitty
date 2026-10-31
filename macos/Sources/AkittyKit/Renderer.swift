import AppKit
import MetalKit
import CoreText
import os

public struct RendererHealth {
    public private(set) var failure: String?
    public var usesSoftware: Bool { failure != nil }
    public mutating func fail(_ message: String) { if failure == nil { failure = message } }
}

/// Grid metrics in points plus the backing scale: the coordinate space shared by the rasterizer and the presenter.
struct GridGeometry: Equatable {
    let cols: Int, rows: Int
    let cell: CGSize
    let scale: CGFloat
    /// The grid rectangle in device pixels, top-left origin — exactly where the CPU path clips images.
    var rect: CGRect {
        CGRect(x: GridRasterizer.margin * scale, y: GridRasterizer.margin * scale,
               width: CGFloat(cols) * cell.width * scale, height: CGFloat(rows) * cell.height * scale)
    }
}

/// Per-draw uniform of the image pipeline: destination rect in NDC plus source rect in texture UV.
struct Quad {
    var destX: Float, destY: Float, destW: Float, destH: Float
    var srcU: Float, srcV: Float, srcW: Float, srcH: Float
}

@MainActor final class MetalPresenter: NSObject, MTKViewDelegate {
    let view: MTKView
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let nearest: MTLSamplerState?
    private let linear: MTLSamplerState?
    private(set) var texture: MTLTexture?
    private(set) var backgroundLayer: MTLTexture?
    private(set) var foregroundLayer: MTLTexture?
    /// One texture per placed image, re-uploaded only when the core reports a new generation.
    struct ImageBinding { let generation: UInt64; let texture: MTLTexture }
    private(set) var imageTextures: [UInt32: ImageBinding] = [:]
    /// Placements sorted by (z, snapshot order): the exact draw order of the CPU path.
    private(set) var placements: [ImagePlacement] = []
    private(set) var grid: GridGeometry?
    /// Whether frames composite the two text layers and the image textures, rather than the single bitmap.
    private(set) var layered = false
    var onFailure: ((String) -> Void)?
    init(forceFailure: Bool = false, forceShaderFailure: Bool = false) throws {
        guard !forceFailure, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw AkittyError.core("Metal device unavailable") }
        self.device = device
        self.queue = queue
        view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true; view.enableSetNeedsDisplay = true
        view.clearColor = Self.clearColor
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float2 uv; };
        vertex Out vertex_main(uint id [[vertex_id]]) {
            float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
            Out o; o.position=float4(p[id],0,1); o.uv=float2((p[id].x+1)*0.5,1-(p[id].y+1)*0.5); return o;
        }
        fragment float4 fragment_main(Out in [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
            return image.sample(s,in.uv);
        }
        struct Quad { float4 dest; float4 source; };
        struct ImageOut { float4 position [[position]]; float2 uv; };
        vertex ImageOut image_vertex(uint id [[vertex_id]], constant Quad &quad [[buffer(0)]]) {
            float2 corners[4] = { quad.dest.xy, quad.dest.xy+float2(quad.dest.z,0), quad.dest.xy+float2(0,quad.dest.w), quad.dest.xy+quad.dest.zw };
            float2 uvs[4] = { quad.source.xy, quad.source.xy+float2(quad.source.z,0), quad.source.xy+float2(0,quad.source.w), quad.source.xy+quad.source.zw };
            ImageOut o; o.position=float4(corners[id],0,1); o.uv=uvs[id]; return o;
        }
        fragment float4 image_fragment(ImageOut in [[stage_in]], texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
            return image.sample(s,in.uv);
        }
        """
        let shader = forceShaderFailure || ProcessInfo.processInfo.environment["AKITTY_FORCE_SHADER_ERROR"] == "1" ? "invalid shader" : source
        let library = try device.makeLibrary(source: shader, options: nil)
        func state(_ vertex: String, _ fragment: String, sourceFactor: MTLBlendFactor) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // Layer bitmaps and image textures are both premultiplied.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = sourceFactor
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = sourceFactor
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        pipeline = try state("vertex_main", "fragment_main", sourceFactor: .one)
        // Image textures hold the device-RGB premultiplied pixels the CPU path would draw, so both pipelines blend alike.
        imagePipeline = try state("image_vertex", "image_fragment", sourceFactor: .one)
        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor(); descriptor.minFilter = filter; descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)
        }
        nearest = sampler(.nearest); linear = sampler(.linear)
        super.init()
        view.delegate = self
    }
    /// Commands submitted and not yet completed; the texture is only written in place when this is zero.
    private let pending = PendingCount()
    final class PendingCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func add(_ delta: Int) { lock.lock(); value += delta; lock.unlock() }
    }
    /// `damage` is the range of bitmap pixel rows that changed since the last call (nil: all of them).
    func update(bitmap: CGContext, damage: Range<Int>? = nil) throws {
        // Leaving the layered path frees its layer and image textures.
        if layered { layered = false; backgroundLayer = nil; foregroundLayer = nil; imageTextures = [:]; placements = [] }
        texture = try upload(into: texture, bitmap: bitmap, damage: damage)
        view.needsDisplay = true
    }
    /// The layered Metal frame: both text layers with their shared damage, images re-synced by generation.
    func updateLayers(background: CGContext, foreground: CGContext, damage: Range<Int>?, grid: GridGeometry, placements: [ImagePlacement], pixels: [UInt32: ImageStore.Entry]) throws {
        try syncImages(placements: placements, pixels: pixels)
        self.grid = grid; self.placements = Self.ordered(placements)
        backgroundLayer = try upload(into: backgroundLayer, bitmap: background, damage: damage)
        foregroundLayer = try upload(into: foregroundLayer, bitmap: foreground, damage: damage)
        layered = true; texture = nil
        view.needsDisplay = true
    }
    /// An image-only frame: the text layers are still valid, so only image textures and geometry move.
    func updateImages(placements: [ImagePlacement], pixels: [UInt32: ImageStore.Entry], grid: GridGeometry) throws {
        try syncImages(placements: placements, pixels: pixels)
        self.grid = grid; self.placements = Self.ordered(placements)
        view.needsDisplay = true
    }
    /// Kitty z-index ties keep snapshot order, so sort with the original offset as the tie-break.
    nonisolated static func ordered(_ placements: [ImagePlacement]) -> [ImagePlacement] {
        placements.enumerated().sorted { ($0.element.z, $0.offset) < ($1.element.z, $1.offset) }.map(\.element)
    }
    /// Same partial-upload rule as the single texture: replace damaged rows in place when the GPU is idle.
    private func upload(into current: MTLTexture?, bitmap: CGContext, damage: Range<Int>?) throws -> MTLTexture {
        guard let data = bitmap.data else { throw AkittyError.core("Render bitmap unavailable") }
        if let current, let damage, current.width == bitmap.width, current.height == bitmap.height, pending.count == 0 {
            // Nothing on the GPU is reading the texture, so upload only the rows that changed.
            if !damage.isEmpty {
                current.replace(region: MTLRegionMake2D(0, damage.lowerBound, bitmap.width, damage.count), mipmapLevel: 0,
                                withBytes: data + damage.lowerBound * bitmap.bytesPerRow, bytesPerRow: bitmap.bytesPerRow)
            }
            return current
        }
        // A frame still owns the current texture (or the size changed): give this one a fresh, fully uploaded texture.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: bitmap.width, height: bitmap.height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let next = device.makeTexture(descriptor: descriptor) else { throw AkittyError.core("Metal texture allocation failed") }
        next.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0, withBytes: data, bytesPerRow: bitmap.bytesPerRow)
        return next
    }
    /// The default background as the CPU bitmaps store it (device RGB), so layered frames clear to the same bytes.
    static let clearColor: MTLClearColor = {
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.setFillColor(CGColor(red: 8/255, green: 10/255, blue: 13/255, alpha: 1)); context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return MTLClearColor(red: Double(pixel[2]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[0]) / 255, alpha: 1)
    }()
    /// Uploads image textures whose generation changed and drops the ones no longer placed.
    private func syncImages(placements: [ImagePlacement], pixels: [UInt32: ImageStore.Entry]) throws {
        var wanted: Set<UInt32> = []
        for placement in placements {
            wanted.insert(placement.id)
            if let binding = imageTextures[placement.id], binding.generation == placement.gen { continue }
            // Pixels not yet fetched for this generation leave the previous texture up rather than a gap.
            guard let entry = pixels[placement.id], entry.generation == placement.gen,
                  let bgra = entry.device ?? ImageStore.devicePixels(entry.rgba, width: entry.width, height: entry.height) else { continue }
            let region = MTLRegionMake2D(0, 0, entry.width, entry.height)
            // Rewrite in place only while no submitted frame can still be sampling the texture.
            if let binding = imageTextures[placement.id], binding.texture.width == entry.width, binding.texture.height == entry.height, pending.count == 0 {
                bgra.withUnsafeBytes { binding.texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: entry.width * 4) }
                imageTextures[placement.id] = ImageBinding(generation: placement.gen, texture: binding.texture)
                continue
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: entry.width, height: entry.height, mipmapped: false)
            descriptor.usage = .shaderRead; descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw AkittyError.core("Metal texture allocation failed") }
            bgra.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: entry.width * 4) }
            imageTextures[placement.id] = ImageBinding(generation: placement.gen, texture: texture)
        }
        imageTextures = imageTextures.filter { wanted.contains($0.key) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard layered || texture != nil else { return }
        // Occluded windows legitimately have no drawable; no frame was submitted.
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { onFailure?("Metal command allocation failed"); return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.clearColor
        if layered {
            encode(encoder, width: drawable.texture.width, height: drawable.texture.height)
        } else if let texture {
            // Single-texture frames: the pre-layer composite path (also used by tests).
            encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        pending.add(1)
        let pending = self.pending
        command.addCompletedHandler { [weak self] completed in
            pending.add(-1)
            if completed.status == .error {
                let message = completed.error?.localizedDescription ?? "GPU command failed"
                DispatchQueue.main.async { self?.onFailure?(message) }
            }
        }
        command.present(drawable); command.commit()
    }
    /// The layered frame: clear to the default background, then z bands around the two text layers,
    /// everything after the first band clipped to the grid area in drawable pixels.
    private func encode(_ encoder: MTLRenderCommandEncoder, width: Int, height: Int) {
        scissor(to: grid?.rect, width: width, height: height, encoder: encoder)
        drawImages(where: { $0.z < GridRasterizer.underlayZ }, encoder: encoder, width: width, height: height)
        drawLayer(backgroundLayer, encoder: encoder)
        drawImages(where: { GridRasterizer.underlayZ <= $0.z && $0.z < 0 }, encoder: encoder, width: width, height: height)
        drawLayer(foregroundLayer, encoder: encoder)
        drawImages(where: { $0.z >= 0 }, encoder: encoder, width: width, height: height)
    }
    private func scissor(to rect: CGRect?, width: Int, height: Int, encoder: MTLRenderCommandEncoder) {
        guard let rect else { return }
        // Clamp to the attachment: Metal validation aborts on a scissor that reaches outside it.
        let x = max(0, Int(rect.minX)), y = max(0, Int(rect.minY))
        let w = min(width - x, Int(ceil(rect.maxX)) - x), h = min(height - y, Int(ceil(rect.maxY)) - y)
        if w > 0, h > 0 { encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: w, height: h)) }
    }
    private func drawLayer(_ texture: MTLTexture?, encoder: MTLRenderCommandEncoder) {
        guard let texture else { return }
        encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
    private func drawImages(where include: (ImagePlacement) -> Bool, encoder: MTLRenderCommandEncoder, width: Int, height: Int) {
        for placement in placements where include(placement) { drawImage(placement, encoder: encoder, width: width, height: height) }
    }
    /// One textured quad. The destination mirrors the CPU geometry exactly: device pixels, y downwards,
    /// ox/oy and dw/dh already in device pixels, points converted as px = point * scale.
    private func drawImage(_ placement: ImagePlacement, encoder: MTLRenderCommandEncoder, width: Int, height: Int) {
        guard let grid, let binding = imageTextures[placement.id] else { return }
        let source = placement.sourceRect
        guard source.width > 0, source.height > 0 else { return }
        let texture = binding.texture, scale = grid.scale
        let ox = CGFloat(placement.ox ?? 0), oy = CGFloat(placement.oy ?? 0)
        let x = (GridRasterizer.margin + CGFloat(placement.col) * grid.cell.width) * scale + ox
        let y = (GridRasterizer.margin + CGFloat(placement.row) * grid.cell.height) * scale + oy
        let boundW = CGFloat(placement.cols) * grid.cell.width * scale - ox, boundH = CGFloat(placement.rows) * grid.cell.height * scale - oy
        let w = placement.dw.map { CGFloat($0) } ?? boundW, h = placement.dh.map { CGFloat($0) } ?? boundH
        guard w > 0, h > 0 else { return }
        var quad = Quad(destX: Float(x / CGFloat(width) * 2 - 1), destY: Float(1 - y / CGFloat(height) * 2),
                        destW: Float(w / CGFloat(width) * 2), destH: Float(-h / CGFloat(height) * 2),
                        srcU: Float(source.minX / CGFloat(texture.width)), srcV: Float(source.minY / CGFloat(texture.height)),
                        srcW: Float(source.width / CGFloat(texture.width)), srcH: Float(source.height / CGFloat(texture.height)))
        encoder.setRenderPipelineState(imagePipeline); encoder.setFragmentTexture(texture, index: 0)
        // 1:1 images stay exact; everything else is resampled smoothly, like the CPU path's interpolation choice.
        let exact = Int(w.rounded()) == Int(source.width) && Int(h.rounded()) == Int(source.height)
        encoder.setFragmentSamplerState(exact ? nearest : linear, index: 0)
        encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    /// Renders the current layered frame into an offscreen texture and reads the BGRA bytes back; for equivalence tests.
    func renderOffscreen(width: Int, height: Int) throws -> Data {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else { throw AkittyError.core("Metal offscreen allocation failed") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.clearColor
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw AkittyError.core("Metal command allocation failed") }
        encode(encoder, width: width, height: height)
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        if command.status == .error { throw AkittyError.core(command.error?.localizedDescription ?? "GPU command failed") }
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }
}

/// Decoded Kitty graphics images, refreshed from the core when a placement's generation changes.
final class ImageStore: @unchecked Sendable {
    /// Raw pixels exactly as the core returns them: straight-alpha RGBA, ready for a Metal texture.
    struct Entry { let generation: UInt64; let width: Int; let height: Int; let rgba: Data; var image: CGImage? = nil; var device: Data? = nil }
    private let lock = NSLock()
    private var table: [UInt32: Entry] = [:]
    /// A copy of the raw pixels; the Metal path wraps these in textures and never needs a CGImage.
    var entries: [UInt32: Entry] { lock.lock(); defer { lock.unlock() }; return table }
    /// CGImages for the software path, created on first use and cached until the generation changes.
    var images: [UInt32: CGImage] {
        lock.lock(); defer { lock.unlock() }
        var result: [UInt32: CGImage] = [:]
        for (id, entry) in table {
            if let image = entry.image { result[id] = image; continue }
            guard let image = Self.makeImage(entry.rgba, width: entry.width, height: entry.height) else { continue }
            table[id]?.image = image; result[id] = image
        }
        return result
    }
    func sync(_ placements: [ImagePlacement], session: TerminalSession) {
        var wanted: [UInt32: ImagePlacement] = [:]
        for placement in placements { wanted[placement.id] = placement }
        for (id, placement) in wanted {
            lock.lock(); let current = table[id]?.generation; lock.unlock()
            guard current != placement.gen,
                  let pixels = session.imagePixels(id, width: placement.w, height: placement.h) else { continue }
            lock.lock()
            // Converted here, off the main thread, so the Metal path only uploads.
            table[id] = Entry(generation: placement.gen, width: placement.w, height: placement.h, rgba: pixels,
                              device: Self.devicePixels(pixels, width: placement.w, height: placement.h))
            lock.unlock()
        }
        lock.lock(); table = table.filter { wanted[$0.key] != nil }; lock.unlock()
    }
    /// The pixels as the CPU path composites them: drawn into a device-RGB premultiplied BGRA bitmap, the format of the
    /// layer bitmaps, so a Metal texture made from them matches the software frame.
    static func devicePixels(_ rgba: Data, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4, let image = makeImage(rgba, width: width, height: height) else { return nil }
        var out = Data(count: width * height * 4)
        let drawn: Bool = out.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? out : nil
    }
    static func makeImage(_ pixels: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Rasterizes snapshots into a bitmap. An instance keeps its bitmap, fonts and glyph cache between frames so a frame
/// that only changed a few rows repaints just those rows. Use one instance from one queue; `make` is the stateless form.
final class GridRasterizer: @unchecked Sendable {
    struct Frame {
        let context: CGContext
        /// Bitmap pixel rows (top-down, as stored) that changed since the previous frame, or nil when everything may have.
        let damage: Range<Int>?
    }
    /// The layered Metal frame: same damage tracking, but the text is split into two transparent bitmaps.
    struct LayeredFrame {
        let background: CGContext
        let foreground: CGContext
        let damage: Range<Int>?
    }
    private struct Layout: Equatable {
        var width: Int, height: Int, scale: CGFloat, fontName: String, cjkFontName: String, fontSize: CGFloat, cell: CGSize, cols: Int, rows: Int
    }
    private struct GlyphKey: Hashable { var style: UInt8, fg: UInt32, text: String }
    static let margin: CGFloat = 8
    private static let maxGlyphs = 8192
    /// Truecolor output can name any of 16.7M colours, so the colour cache is capped like the glyph cache.
    static let maxColors = 4096
    /// Kitty's lowest z layer: images below this draw under non-default cell backgrounds.
    static let underlayZ = -1_073_741_824
    /// The core's resolved default background, which the frame fill already paints.
    static let defaultBackground: [UInt8] = [8, 10, 13]

    private var context: CGContext?
    private var layout: Layout?
    private var base: CTFont?
    private var faces: [CTFont] = []
    /// `ink` is set only for lines with non-ASCII text, which are fitted into their cell box; ASCII keeps the plain path.
    /// `run` is the plain path's single font run, drawn in batches when its ink stays inside the cell (see `inside`).
    private struct Glyph { let line: CTLine; let ink: CGRect?; let run: Run? }
    private struct Run { let font: CTFont; let glyphs: [CGGlyph]; let positions: [CGPoint]; let bounds: CGRect }
    /// Glyphs of one font and colour gathered for a single `CTFontDrawGlyphs` call.
    private struct Batch { let font: CTFont; let color: CGColor; var glyphs: [CGGlyph] = []; var positions: [CGPoint] = [] }
    private struct BatchKey: Hashable { let font: ObjectIdentifier; let fg: UInt32 }
    private var glyphs: [GlyphKey: Glyph] = [:]
    private var colors: [UInt32: CGColor] = [:]
    private var lastCursorRow: Int?
    private var lastComposition = ""
    private var lastHadImages = false
    /// What this instance paints: everything, or one of the two transparent layers of the Metal image path.
    enum Layer { case all, background, foreground }
    private let layer: Layer
    /// False draws every glyph through its own clipped `CTLineDraw`; tests compare the batched path against it.
    let batchesGlyphs: Bool
    /// Glyphs the last frame drew in batches rather than clipped one by one.
    private(set) var batchedGlyphs = 0
    init(layer: Layer = .all, batchesGlyphs: Bool = true) { self.layer = layer; self.batchesGlyphs = batchesGlyphs }
    /// The layer passes, created on first layered frame and kept for their bitmaps and damage state while images show.
    /// A single-bitmap frame drops them, so their two window-sized bitmaps do not outlive the last image.
    private var layerPasses: (background: GridRasterizer, foreground: GridRasterizer)?
    var hasLayerPasses: Bool { layerPasses != nil }
    var cachedColors: Int { colors.count }

    static func make(snapshot: Snapshot, size: CGSize, scale: CGFloat, fontName: String, fontSize: CGFloat, cellSize: CGSize, composition: String, cjkFontName: String = "", images: [UInt32: CGImage] = [:]) throws -> CGContext {
        try GridRasterizer().render(snapshot: snapshot, damage: nil, size: size, scale: scale, fontName: fontName, fontSize: fontSize, cellSize: cellSize, composition: composition, cjkFontName: cjkFontName, images: images, reuse: false).context
    }

    /// `damage` lists the grid rows whose content changed since the last frame this instance rendered (nil: unknown, so
    /// repaint everything). With `reuse` false the bitmap is not kept, so the caller may hold it while the next frame renders.
    func render(snapshot: Snapshot, damage: Set<Int>?, size: CGSize, scale: CGFloat, fontName: String, fontSize: CGFloat, cellSize: CGSize, composition: String, cjkFontName: String = "", images: [UInt32: CGImage] = [:], reuse: Bool = true) throws -> Frame {
        if layer == .all { layerPasses = nil }
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard width <= 16384, height <= 16384, width * height <= 33_554_432 else {
            throw AkittyError.core("Terminal bitmap exceeds rendering limits")
        }
        let wanted = Layout(width: width, height: height, scale: scale, fontName: fontName, cjkFontName: cjkFontName, fontSize: fontSize, cell: cellSize, cols: snapshot.cols, rows: snapshot.rows)
        // Only the all-in-one bitmap draws images, so only it must repaint fully around them.
        let hasImages = layer == .all && !(snapshot.images ?? []).isEmpty
        var rows = damage
        if !reuse || context == nil || layout != wanted || hasImages || lastHadImages { rows = nil }

        let context: CGContext
        if reuse, let existing = self.context, layout == wanted { context = existing }
        else {
            guard let created = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                throw AkittyError.core("Terminal bitmap exceeds rendering limits")
            }
            created.scaleBy(x: scale, y: scale)
            context = created
            rows = nil
        }
        if layout != wanted || base == nil {
            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            base = font
            // Every face gets a CJK-first cascade so unified Han characters use the regional shapes the user expects.
            let languages = Locale.preferredLanguages
            faces = [font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .boldTrait, .boldTrait) ?? font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .italicTrait, .italicTrait) ?? font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]) ?? font]
                .map { GlyphFonts.cascadeFont(base: $0, cjkFontName: cjkFontName, languages: languages) }
            glyphs.removeAll()
        }
        let base = self.base!
        if reuse { self.context = context; layout = wanted } else { self.context = nil; layout = nil }

        let cursorRow = snapshot.cursor.row
        if var set = rows {
            // The cursor and any composition text are drawn over the row, so both its old and new rows need repainting.
            // The background layer has no cursor; the foreground layer only repaints a cursor it draws.
            if layer != .background {
                if let last = lastCursorRow { set.insert(last) }
                if layer == .all || snapshot.cursor.visible { set.insert(cursorRow) }
            }
            rows = set.filter { (0..<snapshot.rows).contains($0) }
        }
        lastCursorRow = snapshot.cursor.visible ? cursorRow : nil
        lastComposition = composition
        lastHadImages = hasImages

        let gridTop = size.height - Self.margin
        func band(_ row: Int) -> CGRect { CGRect(x: 0, y: gridTop - CGFloat(row + 1) * cellSize.height, width: size.width, height: cellSize.height) }
        func rect(_ cell: Cell) -> CGRect {
            CGRect(x: Self.margin + CGFloat(cell.col) * cellSize.width, y: gridTop - CGFloat(cell.row + 1) * cellSize.height,
                   width: cellSize.width * (cell.wide ? 2 : 1), height: cellSize.height)
        }
        let background = CGColor(red: 8/255, green: 10/255, blue: 13/255, alpha: 1)

        if let rows, rows.isEmpty { return Frame(context: context, damage: 0..<0) }
        context.saveGState(); defer { context.restoreGState() }
        // Layer bitmaps start transparent, so the Metal clear colour and the images below them show through.
        if layer != .all { context.setBlendMode(.copy) }
        context.setFillColor(layer == .all ? background : CGColor(gray: 0, alpha: 0))
        let cells: [Cell]
        if let rows {
            context.clip(to: rows.map(band))
            context.fill(rows.map(band))
            cells = snapshot.cells.filter { rows.contains($0.row) }
        } else {
            context.fill(CGRect(origin: .zero, size: size))
            cells = snapshot.cells
        }
        context.setBlendMode(.normal)
        // The background layer stops after the cell fills; the foreground layer skips them.
        let fills = layer == .foreground ? [] : cells, text = layer == .background ? [] : cells

        // Kitty z-index ties keep snapshot order, so sort with the original offset as the tie-break.
        let placements = (snapshot.images ?? []).enumerated().sorted { ($0.element.z, $0.offset) < ($1.element.z, $1.offset) }.map(\.element)
        let gridRect = CGRect(x: Self.margin, y: gridTop - CGFloat(snapshot.rows) * cellSize.height, width: CGFloat(snapshot.cols) * cellSize.width, height: CGFloat(snapshot.rows) * cellSize.height)
        func drawImages(_ include: (ImagePlacement) -> Bool) {
            guard layer == .all else { return }
            context.saveGState(); defer { context.restoreGState() }
            context.clip(to: gridRect)
            for placement in placements where include(placement) {
                guard let image = images[placement.id] else { continue }
                let source = placement.sourceRect
                guard source.width > 0, source.height > 0 else { continue }
                // Offsets and destination sizes are device pixels; the grid is drawn in points, so scale them down.
                let ox = CGFloat(placement.ox ?? 0) / scale, oy = CGFloat(placement.oy ?? 0) / scale
                let boundW = CGFloat(placement.cols) * cellSize.width - ox, boundH = CGFloat(placement.rows) * cellSize.height - oy
                let width = placement.dw.map { CGFloat($0) / scale } ?? boundW, height = placement.dh.map { CGFloat($0) / scale } ?? boundH
                guard width > 0, height > 0 else { continue }
                let full = source.minX == 0 && source.minY == 0 && source.width == CGFloat(image.width) && source.height == CGFloat(image.height)
                let cropped = full ? image : (image.cropping(to: source) ?? image)
                // 1:1 images stay exact; everything else is resampled smoothly.
                let exact = Int((width * scale).rounded()) == Int(source.width) && Int((height * scale).rounded()) == Int(source.height)
                context.interpolationQuality = exact ? .none : .high
                context.draw(cropped, in: CGRect(x: Self.margin + CGFloat(placement.col) * cellSize.width + ox,
                                                 y: gridTop - CGFloat(placement.row) * cellSize.height - oy - height,
                                                 width: width, height: height))
            }
        }
        // Images below z = -2^30 are drawn under every non-default cell background; default-background cells were
        // already painted by the fill above, so skipping them leaves those images visible.
        drawImages { $0.z < Self.underlayZ }
        for cell in fills where cell.selected || cell.search || cell.bg != Self.defaultBackground {
            let fill: CGColor = if cell.selected { CGColor(red: 0.20, green: 0.31, blue: 0.48, alpha: 1) }
                else if cell.activeSearch { CGColor(red: 0.62, green: 0.46, blue: 0.12, alpha: 1) }
                else if cell.search { CGColor(red: 0.40, green: 0.32, blue: 0.10, alpha: 1) }
                else { color(cell.bg) }
            context.setFillColor(fill); context.fill(rect(cell))
        }
        // Remaining negative z-index images sit between the cell backgrounds and the text. Frames with images are always full.
        drawImages { $0.z >= Self.underlayZ && $0.z < 0 }
        // Draw glyphs after every background: a wide-cell spacer must never
        // paint over the second half of the preceding CJK/emoji glyph.
        let descent = CTFontGetDescent(base)
        var batches: [BatchKey: Batch] = [:]
        for item in GlyphClusters.merge(text) {
            let cell = item.cell, text = item.text
            if text.isEmpty || text == " " { continue }
            var box = rect(cell); box.size.width = cellSize.width * CGFloat(item.columns)
            // Box drawing, blocks and braille fill the cell exactly instead of going through the font, which leaves row gaps.
            if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, CellGlyphs.handles(scalar) {
                CellGlyphs.draw(scalar, in: box, scale: scale, color: color(cell.fg), context: context); continue
            }
            let style = (cell.bold ? 1 : 0) + (cell.italic ? 2 : 0)
            let key = GlyphKey(style: UInt8(style), fg: Self.pack(cell.fg), text: text)
            let glyph: Glyph
            if let cached = glyphs[key] { glyph = cached }
            else {
                let attrs: [NSAttributedString.Key: Any] = [.font: faces[style], .foregroundColor: color(cell.fg), .ligature: 0]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                let ascii = text.utf8.allSatisfy { $0 < 0x80 }
                glyph = Glyph(line: line, ink: ascii ? nil : CTLineGetBoundsWithOptions(line, .useGlyphPathBounds), run: ascii ? Self.run(of: line) : nil)
                if glyphs.count >= Self.maxGlyphs { glyphs.removeAll(keepingCapacity: true) }
                glyphs[key] = glyph
            }
            let origin = CGPoint(x: box.minX, y: box.minY + descent + 2)
            // The per-cell clip changes nothing for a glyph whose ink stays inside its cell, so those skip it and
            // are drawn together: the same bitmap at about half the cost of a full frame of text.
            if batchesGlyphs, glyph.ink == nil, let run = glyph.run, Self.inside(run.bounds.offsetBy(dx: origin.x, dy: origin.y), box, scale: scale) {
                let fg = Self.pack(cell.fg)
                let key = BatchKey(font: ObjectIdentifier(run.font), fg: fg)
                if batches[key] == nil { batches[key] = Batch(font: run.font, color: color(cell.fg)) }
                batches[key]!.glyphs += run.glyphs
                batches[key]!.positions += run.positions.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                continue
            }
            context.saveGState(); context.clip(to: box)
            if let ink = glyph.ink {
                let place = GlyphFonts.placement(ink: ink, box: box, baseline: box.minY + descent + 2, centre: item.columns == 2)
                context.translateBy(x: place.origin.x, y: place.origin.y); context.scaleBy(x: place.scale, y: place.scale); context.textPosition = .zero
            } else { context.textPosition = origin }
            CTLineDraw(glyph.line, context); context.restoreGState()
        }
        // Batched glyphs never leave their cells, so drawing them after the clipped ones changes no pixel.
        // Decorations still draw on top. Glyph positions are relative to the text position, so it is reset.
        context.textPosition = .zero
        batchedGlyphs = batches.values.reduce(0) { $0 + $1.glyphs.count }
        for batch in batches.values {
            context.setFillColor(batch.color)
            CTFontDrawGlyphs(batch.font, batch.glyphs, batch.positions, batch.glyphs.count, context)
        }
        // Decorations are drawn per cell so blank cells can still carry underlines and strikethrough.
        let baseline = descent + 2
        for cell in text where cell.underline || cell.strike == true {
            let box = rect(cell)
            let lineColor = color(cell.ucolor ?? cell.fg)
            if cell.underline { Self.underline(context, style: cell.ustyle ?? 1, rect: box, baseline: box.minY + baseline, color: lineColor) }
            if cell.strike == true {
                context.setStrokeColor(color(cell.fg)); context.setLineWidth(1); context.setLineDash(phase: 0, lengths: [])
                let y = box.minY + baseline + CTFontGetXHeight(base) / 2
                context.move(to: CGPoint(x: box.minX, y: y)); context.addLine(to: CGPoint(x: box.maxX, y: y)); context.strokePath()
            }
        }
        drawImages { $0.z >= 0 }
        if layer != .background, snapshot.cursor.visible, rows == nil || rows!.contains(cursorRow) {
            let box = CGRect(x: Self.margin + CGFloat(snapshot.cursor.col) * cellSize.width, y: gridTop - CGFloat(cursorRow + 1) * cellSize.height, width: cellSize.width, height: cellSize.height)
            context.setStrokeColor(CGColor(red: 0.6, green: 0.8, blue: 1, alpha: 1)); context.setLineWidth(1); context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            if !composition.isEmpty {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: composition, attributes: [.font: base, .foregroundColor: CGColor(gray: 1, alpha: 1), .underlineStyle: 1]))
                context.textPosition = CGPoint(x: box.minX, y: box.minY + descent + 2); CTLineDraw(line, context)
            }
        }

        var pixels: Range<Int>?
        if let rows, let first = rows.min(), let last = rows.max() {
            let top = Int(floor((Self.margin + CGFloat(first) * cellSize.height) * scale))
            let bottom = Int(ceil((Self.margin + CGFloat(last + 1) * cellSize.height) * scale))
            // A snapshot can still carry more rows than a just-shrunk view holds, so damaged rows may lie wholly below
            // the bitmap; clamp both bounds so the range stays valid (and empty there) instead of trapping.
            let lower = min(height, max(0, top))
            pixels = lower..<min(height, max(lower, bottom))
        } else if rows != nil { pixels = 0..<0 }
        return Frame(context: context, damage: pixels)
    }

    /// The layered Metal frame: the drawing code and damage tracking of `render`, split into a transparent background
    /// bitmap (cell fills and selection) and a transparent foreground bitmap (glyphs, decorations, cursor) so the GPU can
    /// composite images between them. Images are never drawn here, so an image change needs no text repaint.
    func renderLayers(snapshot: Snapshot, damage: Set<Int>?, size: CGSize, scale: CGFloat, fontName: String, fontSize: CGFloat, cellSize: CGSize, composition: String, cjkFontName: String = "", reuse: Bool = true) throws -> LayeredFrame {
        let passes = layerPasses ?? (GridRasterizer(layer: .background, batchesGlyphs: batchesGlyphs), GridRasterizer(layer: .foreground, batchesGlyphs: batchesGlyphs))
        layerPasses = passes
        let back = try passes.background.render(snapshot: snapshot, damage: damage, size: size, scale: scale, fontName: fontName, fontSize: fontSize, cellSize: cellSize, composition: composition, cjkFontName: cjkFontName, reuse: reuse)
        let front = try passes.foreground.render(snapshot: snapshot, damage: damage, size: size, scale: scale, fontName: fontName, fontSize: fontSize, cellSize: cellSize, composition: composition, cjkFontName: cjkFontName, reuse: reuse)
        // Both layers upload the same rows, so the damage is the span covering both.
        var span: Range<Int>?
        if let a = back.damage, let b = front.damage {
            span = a.isEmpty ? b : b.isEmpty ? a : min(a.lowerBound, b.lowerBound)..<max(a.upperBound, b.upperBound)
        }
        return LayeredFrame(background: back.context, foreground: front.context, damage: span)
    }
    static func underline(_ context: CGContext, style: UInt8, rect: CGRect, baseline: CGFloat, color: CGColor) {
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(color); context.setLineWidth(1); context.setLineDash(phase: 0, lengths: [])
        let y = baseline - 1.5
        switch style {
        case 2:
            for offset in [CGFloat(0), -2] { context.move(to: CGPoint(x: rect.minX, y: y + offset)); context.addLine(to: CGPoint(x: rect.maxX, y: y + offset)) }
        case 3:
            let steps = max(4, Int(rect.width))
            for step in 0...steps {
                let x = rect.minX + rect.width * CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: x, y: y - 1 + sin(CGFloat(step) / CGFloat(steps) * 2 * .pi) )
                if step == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
        case 4:
            context.setLineDash(phase: 0, lengths: [1, 2]); context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y))
        case 5:
            context.setLineDash(phase: 0, lengths: [3, 2]); context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y))
        default:
            context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
    }
    /// The glyphs of a single-run line, with their ink bounds relative to the line origin; nil for anything else.
    private static func run(of line: CTLine) -> Run? {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1, let run = runs.first,
              let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] else { return nil }
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        return Run(font: font as! CTFont, glyphs: glyphs, positions: positions, bounds: CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))
    }
    /// Whether ink drawn at `ink` touches only device pixels that `box` covers completely. Antialiasing can reach one
    /// pixel past the outline, so the ink is widened by a pixel each way; any glyph nearer the edge keeps its clip.
    static func inside(_ ink: CGRect, _ box: CGRect, scale: CGFloat) -> Bool {
        guard !ink.isNull else { return false }
        return floor(ink.minX * scale) - 1 >= ceil(box.minX * scale) && floor(ink.minY * scale) - 1 >= ceil(box.minY * scale)
            && ceil(ink.maxX * scale) + 1 <= floor(box.maxX * scale) && ceil(ink.maxY * scale) + 1 <= floor(box.maxY * scale)
    }
    private static func pack(_ bytes: [UInt8]) -> UInt32 {
        bytes.count == 3 ? UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) : 0x100_0000
    }
    private func color(_ bytes: [UInt8]) -> CGColor {
        let key = Self.pack(bytes)
        if let cached = colors[key] { return cached }
        if colors.count >= Self.maxColors { colors.removeAll(keepingCapacity: true) }
        let made = bytes.count == 3 ? CGColor(red: CGFloat(bytes[0])/255, green: CGFloat(bytes[1])/255, blue: CGFloat(bytes[2])/255, alpha: 1) : CGColor(gray: 1, alpha: 1)
        colors[key] = made
        return made
    }
}
