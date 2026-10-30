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
    private var texture: MTLTexture?
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
    func update(bitmap: CGContext) throws {
        guard let device = view.device, let data = bitmap.data else { throw AkittyError.core("Render bitmap unavailable") }
        // Each submitted frame owns an immutable texture. Reusing a shared
        // texture before GPU completion would race the next CPU upload.
        do {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: bitmap.width, height: bitmap.height, mipmapped: false)
            descriptor.usage = .shaderRead; descriptor.storageMode = .shared
            guard let next = device.makeTexture(descriptor: descriptor) else { throw AkittyError.core("Metal texture allocation failed") }
            texture = next
        }
        texture?.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0, withBytes: data, bytesPerRow: bitmap.bytesPerRow)
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
        command.addCompletedHandler { [weak self] completed in
            if completed.status == .error {
                let message = completed.error?.localizedDescription ?? "GPU command failed"
                DispatchQueue.main.async { self?.onFailure?(message) }
            }
        }
        command.present(drawable); command.commit()
    }
}

enum GridRasterizer {
    static func make(snapshot: Snapshot, size: CGSize, scale: CGFloat, fontName: String, fontSize: CGFloat, cellSize: CGSize, composition: String) throws -> CGContext {
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard width <= 16384, height <= 16384, width * height <= 33_554_432,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw AkittyError.core("Terminal bitmap exceeds rendering limits")
        }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 18/255, green: 22/255, blue: 29/255, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        let base = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let faces = [base,
                     CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .boldTrait, .boldTrait) ?? base,
                     CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .italicTrait, .italicTrait) ?? base,
                     CTFontCreateCopyWithSymbolicTraits(base, 0, nil, [.boldTrait,.italicTrait], [.boldTrait,.italicTrait]) ?? base]
        var glyphs: [String: CTLine] = [:]
        for cell in snapshot.cells {
            let rect = CGRect(x: 8 + CGFloat(cell.col)*cellSize.width, y: size.height - 8 - CGFloat(cell.row+1)*cellSize.height,
                              width: cellSize.width*(cell.wide ? 2 : 1), height: cellSize.height)
            context.setFillColor(cell.selected ? CGColor(red: 0.20, green: 0.31, blue: 0.48, alpha: 1) : color(cell.bg)); context.fill(rect)
        }
        // Draw glyphs after every background: a wide-cell spacer must never
        // paint over the second half of the preceding CJK/emoji glyph.
        for cell in snapshot.cells {
            let rect = CGRect(x: 8 + CGFloat(cell.col)*cellSize.width, y: size.height - 8 - CGFloat(cell.row+1)*cellSize.height,
                              width: cellSize.width*(cell.wide ? 2 : 1), height: cellSize.height)
            if cell.text.isEmpty || cell.text == " " { continue }
            let style = (cell.bold ? 1 : 0) + (cell.italic ? 2 : 0)
            let key = "\(style):\(cell.fg):\(cell.text)"
            let line: CTLine
            if let cached = glyphs[key] { line = cached }
            else {
                var attrs: [NSAttributedString.Key: Any] = [.font: faces[style], .foregroundColor: color(cell.fg), .ligature: 0]
                line = CTLineCreateWithAttributedString(NSAttributedString(string: cell.text, attributes: attrs))
                glyphs[key] = line
            }
            context.saveGState(); context.clip(to: rect)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + CTFontGetDescent(base) + 2)
            CTLineDraw(line, context); context.restoreGState()
        }
        // Decorations are drawn per cell so blank cells can still carry underlines and strikethrough.
        let baseline = CTFontGetDescent(base) + 2
        for cell in snapshot.cells where cell.underline || cell.strike == true {
            let rect = CGRect(x: 8 + CGFloat(cell.col)*cellSize.width, y: size.height - 8 - CGFloat(cell.row+1)*cellSize.height,
                              width: cellSize.width*(cell.wide ? 2 : 1), height: cellSize.height)
            let lineColor = color(cell.ucolor ?? cell.fg)
            if cell.underline { underline(context, style: cell.ustyle ?? 1, rect: rect, baseline: rect.minY + baseline, color: lineColor) }
            if cell.strike == true {
                context.setStrokeColor(color(cell.fg)); context.setLineWidth(1); context.setLineDash(phase: 0, lengths: [])
                let y = rect.minY + baseline + CTFontGetXHeight(base) / 2
                context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y)); context.strokePath()
            }
        }
        if snapshot.cursor.visible {
            let rect = CGRect(x: 8 + CGFloat(snapshot.cursor.col)*cellSize.width, y: size.height - 8 - CGFloat(snapshot.cursor.row+1)*cellSize.height, width: cellSize.width, height: cellSize.height)
            context.setStrokeColor(CGColor(red: 0.6, green: 0.8, blue: 1, alpha: 1)); context.setLineWidth(1); context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            if !composition.isEmpty {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: composition, attributes: [.font: base, .foregroundColor: CGColor(gray: 1, alpha: 1), .underlineStyle: 1]))
                context.textPosition = CGPoint(x: rect.minX, y: rect.minY + CTFontGetDescent(base) + 2); CTLineDraw(line, context)
            }
        }
        return context
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
    private static func color(_ bytes: [UInt8]) -> CGColor {
        guard bytes.count == 3 else { return CGColor(gray: 1, alpha: 1) }
        return CGColor(red: CGFloat(bytes[0])/255, green: CGFloat(bytes[1])/255, blue: CGFloat(bytes[2])/255, alpha: 1)
    }
}
