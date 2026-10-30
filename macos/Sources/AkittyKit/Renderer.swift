import AppKit
import MetalKit
import CoreText
import os

public struct RendererHealth {
    public private(set) var failure: String?
    public var usesSoftware: Bool { failure != nil }
    public mutating func fail(_ message: String) { if failure == nil { failure = message } }
}

@MainActor final class MetalPresenter: NSObject, MTKViewDelegate {
    let view: MTKView
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) var texture: MTLTexture?
    var onFailure: ((String) -> Void)?
    init(forceFailure: Bool = false, forceShaderFailure: Bool = false) throws {
        guard !forceFailure, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw AkittyError.core("Metal device unavailable") }
        self.queue = queue
        view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true; view.enableSetNeedsDisplay = true
        view.clearColor = MTLClearColorMake(0.07, 0.086, 0.114, 1)
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
        """
        let shader = forceShaderFailure || ProcessInfo.processInfo.environment["AKITTY_FORCE_SHADER_ERROR"] == "1" ? "invalid shader" : source
        let library = try device.makeLibrary(source: shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
        guard let device = view.device, let data = bitmap.data else { throw AkittyError.core("Render bitmap unavailable") }
        if let texture, let damage, texture.width == bitmap.width, texture.height == bitmap.height, pending.count == 0 {
            // Nothing on the GPU is reading the texture, so upload only the rows that changed.
            if !damage.isEmpty {
                texture.replace(region: MTLRegionMake2D(0, damage.lowerBound, bitmap.width, damage.count), mipmapLevel: 0,
                                withBytes: data + damage.lowerBound * bitmap.bytesPerRow, bytesPerRow: bitmap.bytesPerRow)
            }
            view.needsDisplay = true
            return
        }
        // A frame still owns the current texture (or the size changed): give this one a fresh, fully uploaded texture.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: bitmap.width, height: bitmap.height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let next = device.makeTexture(descriptor: descriptor) else { throw AkittyError.core("Metal texture allocation failed") }
        next.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0, withBytes: data, bytesPerRow: bitmap.bytesPerRow)
        texture = next
        view.needsDisplay = true
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let texture else { return }
        // Occluded windows legitimately have no drawable; no frame was submitted.
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { onFailure?("Metal command allocation failed"); return }
        encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
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
}

/// Decoded Kitty graphics images, refreshed from the core when a placement's generation changes.
final class ImageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt32: (generation: UInt64, image: CGImage)] = [:]
    var images: [UInt32: CGImage] {
        lock.lock(); defer { lock.unlock() }
        return entries.mapValues(\.image)
    }
    func sync(_ placements: [ImagePlacement], session: TerminalSession) {
        var wanted: [UInt32: ImagePlacement] = [:]
        for placement in placements { wanted[placement.id] = placement }
        for (id, placement) in wanted {
            lock.lock(); let current = entries[id]?.generation; lock.unlock()
            guard current != placement.gen,
                  let pixels = session.imagePixels(id, width: placement.w, height: placement.h),
                  let image = Self.makeImage(pixels, width: placement.w, height: placement.h) else { continue }
            lock.lock(); entries[id] = (placement.gen, image); lock.unlock()
        }
        lock.lock(); entries = entries.filter { wanted[$0.key] != nil }; lock.unlock()
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
    private struct Layout: Equatable {
        var width: Int, height: Int, scale: CGFloat, fontName: String, fontSize: CGFloat, cell: CGSize, cols: Int, rows: Int
    }
    private struct GlyphKey: Hashable { var style: UInt8, fg: UInt32, text: String }
    private static let margin: CGFloat = 8
    private static let maxGlyphs = 8192

    private var context: CGContext?
    private var layout: Layout?
    private var base: CTFont?
    private var faces: [CTFont] = []
    private var glyphs: [GlyphKey: CTLine] = [:]
    private var colors: [UInt32: CGColor] = [:]
    private var lastCursorRow: Int?
    private var lastComposition = ""
    private var lastHadImages = false

    static func make(snapshot: Snapshot, size: CGSize, scale: CGFloat, fontName: String, fontSize: CGFloat, cellSize: CGSize, composition: String, images: [UInt32: CGImage] = [:]) throws -> CGContext {
        try GridRasterizer().render(snapshot: snapshot, damage: nil, size: size, scale: scale, fontName: fontName, fontSize: fontSize, cellSize: cellSize, composition: composition, images: images, reuse: false).context
    }

    /// `damage` lists the grid rows whose content changed since the last frame this instance rendered (nil: unknown, so
    /// repaint everything). With `reuse` false the bitmap is not kept, so the caller may hold it while the next frame renders.
    func render(snapshot: Snapshot, damage: Set<Int>?, size: CGSize, scale: CGFloat, fontName: String, fontSize: CGFloat, cellSize: CGSize, composition: String, images: [UInt32: CGImage] = [:], reuse: Bool = true) throws -> Frame {
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard width <= 16384, height <= 16384, width * height <= 33_554_432 else {
            throw AkittyError.core("Terminal bitmap exceeds rendering limits")
        }
        let wanted = Layout(width: width, height: height, scale: scale, fontName: fontName, fontSize: fontSize, cell: cellSize, cols: snapshot.cols, rows: snapshot.rows)
        let hasImages = !(snapshot.images ?? []).isEmpty
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
            faces = [font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .boldTrait, .boldTrait) ?? font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .italicTrait, .italicTrait) ?? font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]) ?? font]
            glyphs.removeAll()
        }
        let base = self.base!
        if reuse { self.context = context; layout = wanted } else { self.context = nil; layout = nil }

        let cursorRow = snapshot.cursor.row
        if var set = rows {
            // The cursor and any composition text are drawn over the row, so both its old and new rows need repainting.
            if let last = lastCursorRow { set.insert(last) }
            set.insert(cursorRow)
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
        let background = CGColor(red: 18/255, green: 22/255, blue: 29/255, alpha: 1)

        if let rows, rows.isEmpty { return Frame(context: context, damage: 0..<0) }
        context.saveGState(); defer { context.restoreGState() }
        let cells: [Cell]
        if let rows {
            context.clip(to: rows.map(band))
            context.setFillColor(background); context.fill(rows.map(band))
            cells = snapshot.cells.filter { rows.contains($0.row) }
        } else {
            context.setFillColor(background); context.fill(CGRect(origin: .zero, size: size))
            cells = snapshot.cells
        }

        for cell in cells {
            context.setFillColor(cell.selected ? CGColor(red: 0.20, green: 0.31, blue: 0.48, alpha: 1) : color(cell.bg)); context.fill(rect(cell))
        }
        let placements = (snapshot.images ?? []).sorted { $0.z < $1.z }
        let gridRect = CGRect(x: Self.margin, y: gridTop - CGFloat(snapshot.rows) * cellSize.height, width: CGFloat(snapshot.cols) * cellSize.width, height: CGFloat(snapshot.rows) * cellSize.height)
        func drawImages(_ include: (ImagePlacement) -> Bool) {
            context.saveGState(); defer { context.restoreGState() }
            context.clip(to: gridRect); context.interpolationQuality = .high
            for placement in placements where include(placement) {
                guard let image = images[placement.id] else { continue }
                context.draw(image, in: CGRect(x: Self.margin + CGFloat(placement.col) * cellSize.width,
                                               y: gridTop - CGFloat(placement.row + placement.rows) * cellSize.height,
                                               width: CGFloat(placement.cols) * cellSize.width, height: CGFloat(placement.rows) * cellSize.height))
            }
        }
        // Negative z-index images sit between the cell backgrounds and the text. Frames with images are always full.
        drawImages { $0.z < 0 }
        // Draw glyphs after every background: a wide-cell spacer must never
        // paint over the second half of the preceding CJK/emoji glyph.
        let descent = CTFontGetDescent(base)
        for cell in cells {
            if cell.text.isEmpty || cell.text == " " { continue }
            let style = (cell.bold ? 1 : 0) + (cell.italic ? 2 : 0)
            let key = GlyphKey(style: UInt8(style), fg: Self.pack(cell.fg), text: cell.text)
            let line: CTLine
            if let cached = glyphs[key] { line = cached }
            else {
                let attrs: [NSAttributedString.Key: Any] = [.font: faces[style], .foregroundColor: color(cell.fg), .ligature: 0]
                line = CTLineCreateWithAttributedString(NSAttributedString(string: cell.text, attributes: attrs))
                if glyphs.count >= Self.maxGlyphs { glyphs.removeAll(keepingCapacity: true) }
                glyphs[key] = line
            }
            let box = rect(cell)
            context.saveGState(); context.clip(to: box)
            context.textPosition = CGPoint(x: box.minX, y: box.minY + descent + 2)
            CTLineDraw(line, context); context.restoreGState()
        }
        // Decorations are drawn per cell so blank cells can still carry underlines and strikethrough.
        let baseline = descent + 2
        for cell in cells where cell.underline || cell.strike == true {
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
        if snapshot.cursor.visible, rows == nil || rows!.contains(cursorRow) {
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
            pixels = max(0, top)..<min(height, max(top, bottom))
        } else if rows != nil { pixels = 0..<0 }
        return Frame(context: context, damage: pixels)
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
    private static func pack(_ bytes: [UInt8]) -> UInt32 {
        bytes.count == 3 ? UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) : 0x100_0000
    }
    private func color(_ bytes: [UInt8]) -> CGColor {
        let key = Self.pack(bytes)
        if let cached = colors[key] { return cached }
        let made = bytes.count == 3 ? CGColor(red: CGFloat(bytes[0])/255, green: CGFloat(bytes[1])/255, blue: CGFloat(bytes[2])/255, alpha: 1) : CGColor(gray: 1, alpha: 1)
        colors[key] = made
        return made
    }
}
