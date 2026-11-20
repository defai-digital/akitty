import CoreGraphics
import CoreText
import Foundation

/// One quad of a GPU text frame. `uv.zw` of zero makes the quad a solid fill; otherwise it samples the glyph
/// atlas and multiplies the coverage by `rgba`. Colours are device-RGB, premultiplied in the fragment shader.
struct TextInstance: Equatable {
    var destX: Float, destY: Float, destW: Float, destH: Float
    var u: Float, v: Float, uw: Float, uh: Float
    var r: Float, g: Float, b: Float, a: Float
    /// A zero-sized instance draws nothing: the vertex shader sends every corner off-screen.
    static let zero = TextInstance(destX: 0, destY: 0, destW: 0, destH: 0, r: 0, g: 0, b: 0)
    init(destX: Float, destY: Float, destW: Float, destH: Float, u: Float = 0, v: Float = 0, uw: Float = 0, uh: Float = 0,
         r: Float, g: Float, b: Float, a: Float = 1) {
        self.destX = destX; self.destY = destY; self.destW = destW; self.destH = destH
        self.u = u; self.v = v; self.uw = uw; self.uh = uh
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// Why a frame keeps the CPU rasterizer. Each case is content the atlas does not yet reproduce
/// pixel-for-pixel; the software path remains the reference for all of them.
enum TextFallback: String, Equatable, Sendable {
    case composition, images, wideCell, decoratedCell, nonASCII, geometry
}

/// The device-pixel placement a grid has in `GridRasterizer`, recomputed for the GPU path so both draw the
/// same cells at the same pixels. Eligibility guarantees every offset is integral; the fractional parts that
/// remain are constant for the whole grid and are baked into each glyph mask.
struct TextGeometry: Equatable {
    let cols: Int, rows: Int
    let cell: CGSize
    let scale: CGFloat
    let size: CGSize
    let width: Int, height: Int
    let descent: CGFloat, xHeight: CGFloat
    /// Fractional device-pixel offset of a cell's left edge and of its baseline.
    let phaseX: CGFloat, phaseY: CGFloat
    var baseline: CGFloat { descent + 2 }
    var gridTop: CGFloat { size.height - GridRasterizer.margin }

    func box(_ item: Cell) -> CGRect {
        CGRect(x: GridRasterizer.margin + CGFloat(item.col) * cell.width,
               y: gridTop - CGFloat(item.row + 1) * cell.height,
               width: cell.width * (item.wide ? 2 : 1), height: cell.height)
    }
    /// Points (y-up) to device pixels with the drawable's top-left origin. Only integral for eligible grids.
    func deviceBox(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX * scale).rounded(), y: (CGFloat(height) - rect.maxY * scale).rounded(),
               width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }
    /// Top-down device-pixel position of the cell's text baseline.
    func deviceOrigin(_ item: Cell) -> CGPoint {
        let rect = box(item)
        return CGPoint(x: floor(rect.minX * scale), y: deviceOriginY(row: item.row))
    }
    func deviceOriginY(row: Int) -> CGFloat {
        let y = gridTop - CGFloat(row + 1) * cell.height
        return floor(CGFloat(height) - (y + baseline) * scale)
    }
}

enum TextEligibility {
    static func unsupportedFrame(_ snapshot: Snapshot, composition: String) -> TextFallback? {
        if !composition.isEmpty { return .composition }
        if !(snapshot.images ?? []).isEmpty { return .images }
        return nil
    }
    static func unsupportedCell(_ cell: Cell) -> TextFallback? {
        if cell.underline && (cell.ustyle ?? 1) != 1 { return .decoratedCell }
        // A decoration on a wide cell spans two columns and overdraws its spacer, a blend the atlas has not
        // been qualified for. This runs before the blank-text return because an SGR-8 invisible wide lead
        // still carries its underline or strikethrough.
        if cell.wide, cell.underline || cell.strike == true { return .wideCell }
        let text = cell.text
        // A wide spacer and an SGR-8 invisible wide cell carry no glyph; both paths skip them alike.
        if text.isEmpty || text == " " { return nil }
        // Width is settled before the geometric and ASCII tests: a wide box glyph would rasterise a
        // one-column tile that the instance then stretches across two columns, and a wide cell holding
        // printable ASCII is a synthetic state the fitted path must not adopt.
        if cell.wide {
            guard cell.fg.count == 3, fittedScalar(cell) != nil else { return .wideCell }
            return nil
        }
        if text.utf8.count == 1, let byte = text.utf8.first, (0x20...0x7e).contains(byte) { return nil }
        if let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1, CellGlyphs.handles(scalar) { return nil }
        if cell.fg.count == 3, fittedScalar(cell) != nil { return nil }
        return .nonASCII
    }
    /// One standalone scalar that can be fitted into its cell without merging with a neighbour. A wide
    /// cell qualifies on the same terms and is drawn into a two-column box, centred like the CPU path.
    static func fittedScalar(_ cell: Cell) -> Unicode.Scalar? {
        guard !cell.underline || (cell.ustyle ?? 1) == 1,
              cell.text.unicodeScalars.count == 1, let scalar = cell.text.unicodeScalars.first,
              cell.text.utf8.count > 1, !CellGlyphs.handles(scalar) else { return nil }
        // A wide cell's decoration quads span two columns and overdraw its spacer, a blend the atlas has
        // never exercised; wide decorations stay on the CPU reference until they are separately qualified.
        if cell.wide, cell.underline || cell.strike == true { return nil }
        let value = scalar.value
        if value <= 0x1f || (0x7f...0x9f).contains(value) || (0x1f1e6...0x1f1ff).contains(value)
            || value == 0x200d || (0xfe00...0xfe0f).contains(value) || (0xe0100...0xe01ef).contains(value)
            || (0x1f3fb...0x1f3ff).contains(value) || scalar.properties.isEmojiPresentation { return nil }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark, .format: return nil
        default: return scalar
        }
    }
    /// Content the atlas cannot draw identically. Kept separate from geometry so the routing decision is a
    /// pure snapshot scan that costs one pass over the cells the frame already carries.
    static func unsupportedContent(_ snapshot: Snapshot, composition: String) -> TextFallback? {
        if let reason = unsupportedFrame(snapshot, composition: composition) { return reason }
        for cell in snapshot.cells {
            if let reason = unsupportedCell(cell) { return reason }
        }
        return nil
    }
    /// The grid geometry the GPU path can place exactly: integral margins, cells and bitmap in device pixels,
    /// and a backing scale the mask rasteriser has been validated at. Fractional scales keep the CPU path.
    static func geometry(size: CGSize, scale: CGFloat, cell: CGSize, fontName: String, fontSize: CGFloat,
                         cols: Int, rows: Int, descent cachedDescent: CGFloat? = nil, xHeight cachedXHeight: CGFloat? = nil) -> TextGeometry? {
        guard scale.isFinite, scale == scale.rounded(), (1...3).contains(scale), size.width > 0, size.height > 0 else { return nil }
        func integral(_ value: CGFloat) -> Bool { value.isFinite && value == value.rounded() }
        guard integral(GridRasterizer.margin * scale), integral(cell.width * scale), integral(cell.height * scale),
              integral(size.width * scale), integral(size.height * scale) else { return nil }
        // A fitted mask has to fit the atlas texture, and a two-column tile is the widest one. Refusing here
        // keeps an oversized cell from growing the atlas and burning a rebuild before `allocate` fails. The
        // comparison stays in CGFloat so an absurd finite cell size cannot trap in an Int conversion.
        guard cell.width > 0, cell.height > 0,
              (cell.width * 2 * scale).rounded() <= CGFloat(GlyphAtlas.textureSize),
              (cell.height * scale).rounded() <= CGFloat(GlyphAtlas.textureSize) else { return nil }
        let font = cachedDescent == nil || cachedXHeight == nil ? CTFontCreateWithName(fontName as CFString, fontSize, nil) : nil
        let descent = cachedDescent ?? CTFontGetDescent(font!), xHeight = cachedXHeight ?? CTFontGetXHeight(font!)
        guard descent.isFinite, descent >= 0, xHeight.isFinite, xHeight >= 0 else { return nil }
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        let baseline = descent + 2
        let originX = GridRasterizer.margin * scale
        let originY = CGFloat(height) - (size.height - GridRasterizer.margin - cell.height + baseline) * scale
        func fraction(_ value: CGFloat) -> CGFloat { value - floor(value) }
        return TextGeometry(cols: cols, rows: rows, cell: cell, scale: scale, size: size, width: width, height: height,
                            descent: descent, xHeight: xHeight, phaseX: fraction(originX), phaseY: fraction(originY))
    }
    static func fallback(snapshot: Snapshot, composition: String, size: CGSize, scale: CGFloat, cell: CGSize,
                         fontName: String, fontSize: CGFloat) -> TextFallback? {
        if let reason = unsupportedContent(snapshot, composition: composition) { return reason }
        guard geometry(size: size, scale: scale, cell: cell, fontName: fontName, fontSize: fontSize,
                       cols: snapshot.cols, rows: snapshot.rows) != nil else { return .geometry }
        return nil
    }
}

/// A frame the presenter can upload and draw: instance rows plus any new atlas coverage.
struct TextFrame {
    let rows: Int
    /// Ascending instance rows, parallel to `content`.
    let dirtyRows: [Int]
    let content: [[TextInstance]]
    let uploads: [GlyphAtlas.Upload]
    /// The atlas must be recreated: every row was re-encoded because earlier UVs are gone.
    let resetAtlas: Bool
}

/// Bounded coverage atlas for glyph masks.
///
/// macOS applies colour-dependent font smoothing, so one grey coverage mask cannot reproduce coloured text:
/// measured error reaches ~50/255, while a mask rasterised in the text's own colour stays within 2/255. Font masks
/// are therefore keyed by style, text and foreground colour. Geometric cell masks are colour-independent and keyed
/// only by scalar and device geometry. The atlas is shelf-packed, capped in entry count and texture size, and
/// recovers by being recreated when it fills; callers then re-encode every row.
final class GlyphAtlas: @unchecked Sendable {
    struct Upload { let x: Int, y: Int, width: Int, height: Int; let coverage: [UInt8] }
    struct Entry {
        let u: Float, v: Float
        let width: Int, height: Int
        /// Quad origin relative to the cell's floored device origin.
        let dx: Int, dy: Int
    }
    enum Fitted { case blank, entry(Entry) }
    enum Decoration { case underline, strike }
    /// Keyed by scalar, not text: Swift hashes strings by canonical equivalence, so a compatibility
    /// ideograph (U+FA10) collides with its unified form (U+585A) and one glyph's line would be drawn for
    /// the other. Fitted text is always a single scalar, so the scalar is a complete key.
    private struct LineKey: Hashable { let style: UInt8, scalar: UInt32 }
    private struct FittedLine { let line: CTLine, ink: CGRect }
    private enum FittedAnalysis { case unsupported, blank, monochrome(FittedLine) }
    private enum Key: Hashable {
        /// Reached only by printable ASCII, which has no canonical-equivalence collisions. If eligibility
        /// is ever widened to multi-scalar or non-ASCII text, this must stop keying by `String`: Swift
        /// would then alias U+212A (Kelvin sign) with "K" and serve the wrong mask.
        case text(style: UInt8, text: String, fg: UInt32)
        /// Keyed by scalar rather than text: Swift compares strings by canonical equivalence, so a CJK
        /// compatibility ideograph (U+FA10) equals its unified form (U+585A) and hashes the same, while
        /// CoreText draws different ink for each. Columns are part of the key because one column
        /// left-aligns and may shrink the ink, while two columns centre it at full size.
        case fitted(style: UInt8, scalar: UInt32, columns: UInt8, fg: UInt32)
        case decoration(Decoration)
        case cell(scalar: UInt32, width: Int, height: Int, scale: Int)
    }

    /// Side of the single atlas texture: 4 MiB of R8 coverage.
    static let textureSize = 2048
    /// Hard entry cap, independent of packing; bounds the dictionary and the mask count under eviction churn.
    static let maxEntries = 4096
    /// Transparent device pixels around a mask so antialiased ink never touches a neighbouring entry.
    private static let pad = 2
    private static let colorFromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)

    private var entries: [Key: Entry] = [:]
    private var analyses: [LineKey: FittedAnalysis] = [:]
    private var shelfTop = 0, shelfBottom = 0, cursorX = 0
    private(set) var resets = 0
    /// The last lookup ran out of atlas space; the caller resets and retries.
    private(set) var exhausted = false
    var count: Int { entries.count }

    /// Every entry is invalid after a layout change, so the atlas starts over rather than reusing stale UVs.
    func reset() {
        entries.removeAll(keepingCapacity: true)
        // Coverage queued by the attempt that filled the atlas belongs to the old packing and must not reach
        // the new texture, where it could overwrite a live entry at the same coordinates.
        pending.removeAll(keepingCapacity: true)
        shelfTop = 0; shelfBottom = 0; cursorX = 0
        resets += 1; exhausted = false
    }
    func resetAnalysis() { analyses.removeAll(keepingCapacity: true) }
    func clearExhausted() { exhausted = false }

    /// Coverage for one glyph in one colour, rasterising it the first time it is seen.
    func entry(style: UInt8, text: String, fg: [UInt8], face: CTFont, geometry: TextGeometry) -> Entry? {
        guard fg.count == 3 else { return nil }
        let key = Key.text(style: style, text: text, fg: UInt32(fg[0]) << 16 | UInt32(fg[1]) << 8 | UInt32(fg[2]))
        if let cached = entries[key] { return cached }
        guard entries.count < Self.maxEntries else { exhausted = true; return nil }
        guard let mask = Self.rasterize(text: text, face: face, fg: fg, geometry: geometry) else { return nil }
        return insert(mask, key: key)
    }

    func canFit(style: UInt8, scalar: Unicode.Scalar, face: CTFont) -> Bool {
        switch fittedAnalysis(style: style, scalar: scalar, face: face) {
        case .blank, .monochrome: return true
        case .unsupported: return false
        }
    }
    func fittedEntry(style: UInt8, scalar: Unicode.Scalar, columns: Int, fg: [UInt8], face: CTFont,
                     geometry: TextGeometry) -> Fitted? {
        guard fg.count == 3, columns == 1 || columns == 2 else { return nil }
        let key = Key.fitted(style: style, scalar: scalar.value, columns: UInt8(columns),
                             fg: UInt32(fg[0]) << 16 | UInt32(fg[1]) << 8 | UInt32(fg[2]))
        // A cached entry was already proven monochrome under the current face, and the face only changes
        // with a layout change that resets the atlas. Answering from the cache must not pay for a CoreText
        // analysis, which matters once the analysis cache has stopped taking residents.
        if let cached = entries[key] { return .entry(cached) }
        switch fittedAnalysis(style: style, scalar: scalar, face: face) {
        case .unsupported: return nil
        case .blank: return .blank
        case .monochrome(let fitted):
            guard entries.count < Self.maxEntries else { exhausted = true; return nil }
            guard let mask = Self.rasterizeFitted(line: fitted.line, ink: fitted.ink, fg: fg, geometry: geometry,
                                                  columns: columns) else { return nil }
            return insert(mask, key: key).map { .entry($0) }
        }
    }

    /// Geometric glyphs need no font, style or colour key: the same white coverage is tinted by each instance.
    func entry(scalar: Unicode.Scalar, geometry: TextGeometry) -> Entry? {
        guard CellGlyphs.handles(scalar) else { return nil }
        let width = max(1, Int((geometry.cell.width * geometry.scale).rounded()))
        let height = max(1, Int((geometry.cell.height * geometry.scale).rounded()))
        let key = Key.cell(scalar: scalar.value, width: width, height: height, scale: Int(geometry.scale))
        if let cached = entries[key] { return cached }
        guard entries.count < Self.maxEntries else { exhausted = true; return nil }
        guard let mask = Self.rasterize(scalar: scalar, width: width, height: height, geometry: geometry) else { return nil }
        return insert(mask, key: key)
    }

    func decorationEntry(_ kind: Decoration, geometry: TextGeometry) -> Entry? {
        let key = Key.decoration(kind)
        if let cached = entries[key] { return cached }
        guard entries.count < Self.maxEntries else { exhausted = true; return nil }
        guard let mask = Self.rasterizeDecoration(kind, geometry: geometry) else { return nil }
        return insert(mask, key: key)
    }

    private func insert(_ mask: Mask, key: Key) -> Entry? {
        guard let origin = allocate(mask.width, mask.height) else { exhausted = true; return nil }
        let entry = Entry(u: Float(origin.x) / Float(Self.textureSize), v: Float(origin.y) / Float(Self.textureSize),
                          width: mask.width, height: mask.height, dx: mask.dx, dy: mask.dy)
        entries[key] = entry
        pending.append(Upload(x: origin.x, y: origin.y, width: mask.width, height: mask.height, coverage: mask.coverage))
        return entry
    }
    /// Masks rasterised since the last call; the presenter uploads them before the next draw.
    private(set) var pending: [Upload] = []
    func clearPending() { pending.removeAll(keepingCapacity: true) }

    private func allocate(_ width: Int, _ height: Int) -> (x: Int, y: Int)? {
        let size = Self.textureSize
        guard width > 0, height > 0, width <= size, height <= size else { return nil }
        var top = shelfTop, bottom = shelfBottom, x = cursorX
        if x + width > size { top = bottom; x = 0 }
        if x == 0 { bottom = top + height }
        else if top + height > bottom { top = bottom; x = 0; bottom = top + height }
        guard bottom <= size, top >= 0 else { return nil }
        shelfTop = top; shelfBottom = bottom; cursorX = x + width
        return (x, top)
    }

    private static func rasterizeDecoration(_ kind: Decoration, geometry: TextGeometry) -> Mask? {
        let backing = geometry.scale
        let height = max(1, Int((geometry.cell.height * backing).rounded()))
        let rect = CGRect(x: (3 / backing - geometry.cell.width) / 2, y: 0, width: geometry.cell.width, height: geometry.cell.height)
        var pixels = [UInt8](repeating: 0, count: 3 * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 3, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.scaleBy(x: backing, y: backing)
            let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            switch kind {
            case .underline: GridRasterizer.underline(context, style: 1, rect: rect, baseline: geometry.baseline, color: white)
            case .strike: GridRasterizer.strike(context, rect: rect, baseline: geometry.baseline, xHeight: geometry.xHeight, color: white)
            }
            return true
        }
        guard drawn else { return nil }
        var coverage = [UInt8](repeating: 0, count: 3 * height)
        for index in 0..<(3 * height) { coverage[index] = pixels[index * 4 + 3] }
        return Mask(width: 3, height: height, dx: 0, dy: 0, coverage: coverage)
    }

    /// The analysis is a pure function of (style, text, face). A full cache stops taking new residents
    /// rather than evicting them or refusing the glyph: the result is re-derivable, clearing would drop
    /// every hot entry and refill within a few frames on a CJK repertoire larger than the cap, and
    /// refusing would pin the path to the software rasterizer for the rest of the epoch.
    private func fittedAnalysis(style: UInt8, scalar: Unicode.Scalar, face: CTFont) -> FittedAnalysis {
        let key = LineKey(style: style, scalar: scalar.value)
        if let cached = analyses[key] { return cached }
        // Fitted text is exactly one scalar, so the scalar is both the key and the whole analysis input.
        let result = Self.analyse(text: String(scalar), face: face)
        if analyses.count < Self.maxEntries { analyses[key] = result }
        return result
    }

    private static func analyse(text: String, face: CTFont) -> FittedAnalysis {
        let attributes: [NSAttributedString.Key: Any] = [.font: face, colorFromContext: true, .ligature: 0]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        guard CTLineGetGlyphCount(line) > 0, let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else {
            return .unsupported
        }
        for run in runs {
            guard let raw = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] else { return .unsupported }
            let font = raw as! CTFont
            if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { return .unsupported }
        }
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        // A non-finite ink box would poison the placement arithmetic, so it is refused here rather than
        // failing later inside rasterizeFitted after other cells already grew the atlas.
        guard !ink.isNull, ink.minX.isFinite, ink.minY.isFinite, ink.width.isFinite, ink.height.isFinite else {
            return .unsupported
        }
        return ink.isEmpty ? .blank : .monochrome(FittedLine(line: line, ink: ink))
    }

    private struct Mask { let width: Int, height: Int; let dx: Int, dy: Int; let coverage: [UInt8] }

    /// A non-ASCII line fitted into its cell exactly as GridRasterizer fits it, then cropped to that cell.
    /// `columns` is 2 for a wide cell: its box is twice as wide and the CPU path centres the ink in it.
    private static func rasterizeFitted(line: CTLine, ink: CGRect, fg: [UInt8], geometry: TextGeometry,
                                        columns: Int) -> Mask? {
        guard columns == 1 || columns == 2 else { return nil }
        // One product feeds the placement box, the clip and the device-pixel clamp so all three agree.
        let boxWidth = geometry.cell.width * CGFloat(columns)
        let localBox = CGRect(origin: .zero, size: CGSize(width: boxWidth, height: geometry.cell.height))
        let place = GlyphFonts.placement(ink: ink, box: localBox, baseline: geometry.baseline, centre: columns == 2)
        let ink = ink.standardized
        let placed = CGRect(x: place.origin.x + place.scale * ink.minX, y: place.origin.y + place.scale * ink.minY,
                            width: place.scale * ink.width, height: place.scale * ink.height)
        guard placed.minX.isFinite, placed.minY.isFinite, placed.width.isFinite, placed.height.isFinite, !placed.isEmpty else { return nil }
        let backing = geometry.scale
        let cellW = Int((boxWidth * backing).rounded()), cellH = Int((geometry.cell.height * backing).rounded())
        let dx = max(0, Int(floor(placed.minX * backing)) - pad)
        let maxX = min(cellW, Int(ceil(placed.maxX * backing)) + pad)
        let dy = max(0, Int(floor(CGFloat(cellH) - placed.maxY * backing)) - pad)
        let maxY = min(cellH, Int(ceil(CGFloat(cellH) - placed.minY * backing)) + pad)
        let width = maxX - dx, height = maxY - dy
        guard width > 0, height > 0, width <= cellW, height <= cellH else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.scaleBy(x: backing, y: backing)
            context.translateBy(x: -CGFloat(dx) / backing, y: -CGFloat(cellH - dy - height) / backing)
            context.clip(to: localBox)
            context.translateBy(x: place.origin.x, y: place.origin.y)
            context.scaleBy(x: place.scale, y: place.scale)
            context.setFillColor(CGColor(red: CGFloat(fg[0]) / 255, green: CGFloat(fg[1]) / 255, blue: CGFloat(fg[2]) / 255, alpha: 1))
            context.textPosition = .zero
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) { coverage[index] = pixels[index * 4 + 3] }
        return Mask(width: width, height: height, dx: dx, dy: dy, coverage: coverage)
    }

    /// Rasterises one line at the exact device position the CPU path draws it, so an integer-offset blit of
    /// this coverage is the same pixels.
    private static func rasterize(text: String, face: CTFont, fg: [UInt8], geometry: TextGeometry) -> Mask? {
        let attributes: [NSAttributedString.Key: Any] = [.font: face, colorFromContext: true, .ligature: 0]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isNull, ink.width.isFinite, ink.height.isFinite, !ink.isEmpty else { return nil }
        let scale = geometry.scale
        let width = min(textureSize, max(1, Int(ceil(ink.width * scale)) + 2 * pad + 2))
        let height = min(textureSize, max(1, Int(ceil(ink.height * scale)) + 2 * pad + 2))
        // The quad's top-left relative to the floored cell origin. The integer part of the origin cancels, so
        // only the layout's constant fractional phase matters.
        let dx = Int(floor(geometry.phaseX + ink.minX * scale)) - pad
        let dy = Int(floor(geometry.phaseY - ink.maxY * scale)) - pad
        // Baseline position inside the mask, in device pixels from its top-left.
        let x = geometry.phaseX - CGFloat(dx), y = geometry.phaseY - CGFloat(dy)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.scaleBy(x: scale, y: scale)
            // The text's own colour is what makes smoothing match the CPU draw; see the type comment.
            context.setFillColor(CGColor(red: CGFloat(fg[0]) / 255, green: CGFloat(fg[1]) / 255, blue: CGFloat(fg[2]) / 255, alpha: 1))
            context.textPosition = CGPoint(x: x / scale, y: (CGFloat(height) - y) / scale)
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) { coverage[index] = pixels[index * 4 + 3] }
        return Mask(width: width, height: height, dx: dx, dy: dy, coverage: coverage)
    }

    /// Cell geometry is anchored to the device box, not the font baseline. Every eligible cell has zero subpixel phase,
    /// so one exact-size coverage tile can be reused at every row and column without changing seams or antialiasing.
    private static func rasterize(scalar: Unicode.Scalar, width: Int, height: Int, geometry: TextGeometry) -> Mask? {
        guard width > 0, height > 0, width <= textureSize, height <= textureSize else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.scaleBy(x: geometry.scale, y: geometry.scale)
            CellGlyphs.draw(scalar, in: CGRect(origin: .zero, size: geometry.cell), scale: geometry.scale,
                            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1), context: context)
            return true
        }
        guard drawn else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) { coverage[index] = pixels[index * 4 + 3] }
        return Mask(width: width, height: height, dx: 0, dy: 0, coverage: coverage)
    }
}

/// CPU side of the GPU text path: keeps the atlas, the per-row instance lists and damage bookkeeping so an
/// incremental frame rebuilds and uploads only the rows the core marked dirty. Used from the raster queue.
final class TextComposer: @unchecked Sendable {
    private struct Layout: Equatable {
        var width: Int, height: Int, scale: CGFloat, fontName: String, cjkFontName: String, fontSize: CGFloat
        var cell: CGSize, cols: Int, rows: Int, descent: CGFloat, xHeight: CGFloat
        /// Resolved CJK cascade preference; see `GlyphFonts.cascadeKey`. The rasterizer keys on the same
        /// value so a runtime language change rebuilds both font caches on the same frame.
        var cascadeKey: String
    }
    /// Colours named by truecolor output are unbounded, exactly as in the rasterizer; convert each once.
    private static let maxColors = 4096
    /// Full atlas rebuilds allowed per font/scale/grid/theme epoch. A truecolor storm that fills the atlas on
    /// every frame would otherwise rasterise the whole window through CoreText each frame, so after this many
    /// rebuilds the path stands down and the CPU rasterizer takes over until the epoch changes.
    static let maxRebuildsPerEpoch = 2
    /// Frames a suspended composer waits before it is allowed one probation rebuild. Without it, a workload
    /// that outgrew the atlas stays on the software rasterizer until the font, scale, grid or theme changes,
    /// even after its repertoire shrinks; with it, a truecolor storm still costs at most one wasted rebuild
    /// per interval.
    static let suspensionRetryFrames = 600
    private static let colorFromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)

    private var faces: [CTFont] = []
    private var base: CTFont?
    private var layout: Layout?
    private let atlas = GlyphAtlas()
    private var rows: [[TextInstance]] = []
    private var colors: [UInt32: (Float, Float, Float)] = [:]
    private var lastCursorRow: Int?
    /// A successful full-grid scan certifies every row eligible. No-scroll updates retain that certificate only
    /// after rechecking their dirty rows; scrolls and unknown damage always take the full reference scan.
    private var eligibleContentRows: Int?
    private(set) var eligibilityScannedRows = 0
    /// Layout plus appearance: a change re-arms the rebuild budget without invalidating still-valid masks.
    private struct Epoch: Equatable { var layout: Layout; var appearance: RenderAppearance }
    private var epoch: Epoch?
    private var rebuilds = 0
    private var suspendedFrames = 0
    /// A refused or discarded frame may change the atlas and cursor without reaching the presenter.
    /// Keep uploads and reset requests until handoff, and rebuild every row when recovering.
    private var resetPending = false, recoveryPending = false
    private(set) var isSuspended = false
    private(set) var atlasEntries = 0
    private(set) var atlasResets = 0
    private(set) var translatedRowCount = 0
    private(set) var reencodedRowCount = 0

    /// Drops retained rows and masks; the next frame is a full rebuild. Called when the pane leaves its window.
    func releaseFrames() {
        rows = []; layout = nil; lastCursorRow = nil; colors.removeAll(keepingCapacity: true)
        eligibleContentRows = nil; eligibilityScannedRows = 0
        epoch = nil; rebuilds = 0; isSuspended = false; suspendedFrames = 0
        resetPending = false; recoveryPending = false
        atlas.reset(); atlas.resetAnalysis(); atlasEntries = 0; atlasResets = atlas.resets
    }

    /// Builds one frame, or nil when the atlas cannot represent it (the caller then keeps the CPU rasterizer).
    /// Callers that hand off asynchronously defer publication and acknowledge only a successful upload.
    func compose(snapshot: Snapshot, damage: Set<Int>?, size: CGSize, scale: CGFloat, fontName: String, fontSize: CGFloat,
                 cell: CGSize, cjkFontName: String, appearance: RenderAppearance, deferPublication: Bool = false,
                 prevalidated geometry: TextGeometry? = nil, scroll: Int = 0) -> TextFrame? {
        var damage = damage
        guard TextEligibility.unsupportedFrame(snapshot, composition: "") == nil else {
            eligibleContentRows = nil; return nil
        }
        let cachedMetrics = layout.flatMap { $0.fontName == fontName && $0.fontSize == fontSize ? ($0.descent, $0.xHeight) : nil }
        let geometry = if let geometry { geometry } else {
            TextEligibility.geometry(size: size, scale: scale, cell: cell, fontName: fontName,
                                     fontSize: fontSize, cols: snapshot.cols, rows: snapshot.rows,
                                     descent: cachedMetrics?.0, xHeight: cachedMetrics?.1)
        }
        guard let geometry else { eligibleContentRows = nil; return nil }
        let wanted = Layout(width: geometry.width, height: geometry.height, scale: scale, fontName: fontName,
                            cjkFontName: cjkFontName, fontSize: fontSize, cell: cell, cols: snapshot.cols,
                            rows: snapshot.rows, descent: geometry.descent, xHeight: geometry.xHeight,
                            cascadeKey: GlyphFonts.cascadeKey())
        let signature = Epoch(layout: wanted, appearance: appearance)
        let changesEpoch = epoch != signature
        let changesLayout = layout != wanted || base == nil || rows.count != snapshot.rows
        let retrying = isSuspended && !changesEpoch
        if retrying {
            eligibleContentRows = nil
            suspendedFrames += 1
            guard suspendedFrames >= Self.suspensionRetryFrames else { return nil }
            suspendedFrames = 0
        }
        if changesEpoch || changesLayout || recoveryPending || retrying { damage = nil }
        // Validate with the candidate fonts before committing to a new atlas or rebuild budget.
        let fontSet = changesLayout ? Self.makeFonts(fontName: fontName, fontSize: fontSize, cjkFontName: cjkFontName) : nil
        let analysisAtlas = changesLayout ? GlyphAtlas() : atlas
        guard contentEligible(snapshot: snapshot, damage: damage, scroll: scroll,
                              faces: fontSet?.faces ?? faces, analysisAtlas: analysisAtlas) else { return nil }
        if changesEpoch { epoch = signature; rebuilds = 0 }
        // One probation rebuild allows the atlas to recover after the working set shrinks.
        if retrying { rebuilds = Self.maxRebuildsPerEpoch - 1 }
        isSuspended = false; suspendedFrames = 0
        var resetAtlas = resetPending
        if let fontSet {
            // A new font, size, scale or grid invalidates every UV and every row.
            applyFonts(fontSet)
            layout = wanted
            atlas.reset()
            rows = Array(repeating: [], count: snapshot.rows)
            lastCursorRow = nil
            resetAtlas = true
            resetPending = true
        }
        recoveryPending = true
        atlas.clearExhausted()
        var result = build(snapshot: snapshot, damage: damage, geometry: geometry, appearance: appearance,
                           resetAtlas: resetAtlas, scroll: scroll)
        if result == nil, atlas.exhausted {
            // The atlas filled: recreate it and re-encode everything, up to the per-epoch budget.
            guard rebuilds < Self.maxRebuildsPerEpoch else {
                // The probation interval counts from the moment of standing down, not from earlier refusals.
                isSuspended = true; suspendedFrames = 0; atlasEntries = atlas.count; atlasResets = atlas.resets; return nil
            }
            rebuilds += 1
            atlas.reset()
            rows = Array(repeating: [], count: snapshot.rows)
            resetAtlas = true
            resetPending = true
            result = build(snapshot: snapshot, damage: nil, geometry: geometry, appearance: appearance, resetAtlas: true, scroll: 0)
        }
        guard let result else {
            recoveryPending = true; atlasEntries = atlas.count; atlasResets = atlas.resets; return nil
        }
        atlasEntries = atlas.count; atlasResets = atlas.resets
        let frame = TextFrame(rows: snapshot.rows, dirtyRows: result.rows, content: result.content,
                              uploads: atlas.pending, resetAtlas: resetAtlas)
        if !deferPublication { acknowledgePublication() }
        return frame
    }

    private func unsupportedContentCell(_ cell: Cell, faces: [CTFont], analysisAtlas: GlyphAtlas) -> TextFallback? {
        if let reason = TextEligibility.unsupportedCell(cell) { return reason }
        guard let scalar = TextEligibility.fittedScalar(cell) else { return nil }
        let style = UInt8((cell.bold ? 1 : 0) + (cell.italic ? 2 : 0))
        guard let face = faces[safe: Int(style)],
              analysisAtlas.canFit(style: style, scalar: scalar, face: face) else { return .nonASCII }
        return nil
    }

    private func contentEligible(snapshot: Snapshot, damage: Set<Int>?, scroll: Int, faces: [CTFont], analysisAtlas: GlyphAtlas) -> Bool {
        eligibilityScannedRows = 0
        if scroll == 0, eligibleContentRows == snapshot.rows, let damage {
            for row in damage.sorted() where (0..<snapshot.rows).contains(row) {
                eligibilityScannedRows += 1
                if snapshot.cells(in: row).contains(where: { unsupportedContentCell($0, faces: faces, analysisAtlas: analysisAtlas) != nil }) {
                    eligibleContentRows = nil
                    return false
                }
            }
        } else {
            eligibleContentRows = nil
            for cell in snapshot.cells {
                if unsupportedContentCell(cell, faces: faces, analysisAtlas: analysisAtlas) != nil {
                    eligibilityScannedRows = min(snapshot.rows, max(1, cell.row + 1))
                    return false
                }
            }
            eligibilityScannedRows = snapshot.rows
            eligibleContentRows = snapshot.rows
        }
        #if DEBUG
        // The release fast path relies on core damage. Check that contract against the original full scan in tests.
        for cell in snapshot.cells { assert(unsupportedContentCell(cell, faces: faces, analysisAtlas: analysisAtlas) == nil) }
        // The composer iterates raw cells instead of merged clusters. Assert the merge it skipped really
        // would have been the identity, so relaxing eligibility without re-auditing merge fails loudly.
        // One call over the whole grid mirrors the rasterizer and avoids slicing a copy per row.
        let cells = snapshot.cells, merged = GlyphClusters.merge(cells)
        assert(merged.count == cells.count, "an eligible frame must not contain a joined glyph cluster")
        for (item, cell) in zip(merged, cells) {
            assert(item.cell.col == cell.col && item.text == cell.text && item.columns == (cell.wide ? 2 : 1),
                   "an eligible cell must draw alone in a box as wide as the CPU gives it")
        }
        #endif
        return true
    }

    func acknowledgePublication() {
        atlas.clearPending()
        resetPending = false; recoveryPending = false
    }

    private struct FontSet { let base: CTFont, faces: [CTFont] }

    private static func makeFonts(fontName: String, fontSize: CGFloat, cjkFontName: String) -> FontSet {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let languages = Locale.preferredLanguages
        let faces = [font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .boldTrait, .boldTrait) ?? font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .italicTrait, .italicTrait) ?? font,
                     CTFontCreateCopyWithSymbolicTraits(font, 0, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]) ?? font]
            .map { GlyphFonts.cascadeFont(base: $0, cjkFontName: cjkFontName, languages: languages) }
        return FontSet(base: font, faces: faces)
    }

    private func applyFonts(_ fonts: FontSet) {
        base = fonts.base
        faces = fonts.faces
        atlas.resetAnalysis()
    }

    private func build(snapshot: Snapshot, damage: Set<Int>?, geometry: TextGeometry, appearance: RenderAppearance,
                       resetAtlas: Bool, scroll: Int) -> (rows: [Int], content: [[TextInstance]])? {
        translatedRowCount = 0; reencodedRowCount = 0
        if resetAtlas {
            // Pack the uniform full-cell shelves before shorter font masks; interleaving them strands shelf space.
            for cell in snapshot.cells {
                let text = cell.text
                guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
                      scalar.value != 0x2800, CellGlyphs.handles(scalar) else { continue }
                guard atlas.entry(scalar: scalar, geometry: geometry) != nil else { return nil }
            }
        }
        if !resetAtlas, scroll > 0, scroll < snapshot.rows, damage != nil {
            let delta = CGFloat(scroll) * geometry.cell.height * geometry.scale
            // The baseline is floored after several floating-point operations. Integral
            // geometry alone does not prove that a translated row matches a fresh encode.
            // The integral delta also moves cell-fill tops by whole pixels, so fills blit exactly.
            let exact = delta.isFinite && delta > 0 && delta.rounded() == delta
                && (0..<snapshot.rows - scroll).allSatisfy { row in
                    geometry.deviceOriginY(row: row + scroll) - delta == geometry.deviceOriginY(row: row)
                }
            if exact {
                let shiftedCursorRow = lastCursorRow.flatMap { $0 >= scroll ? $0 - scroll : nil }
                var rebuild = damage ?? []
                rebuild.formUnion(snapshot.rows - scroll..<snapshot.rows)
                if let last = shiftedCursorRow { rebuild.insert(last) }
                if snapshot.cursor.visible { rebuild.insert(snapshot.cursor.row) }
                let ordered = rebuild.filter { (0..<snapshot.rows).contains($0) }.sorted()
                // Rows about to be re-encoded skip translation: their instances are replaced anyway.
                var translated = 0
                for row in 0..<snapshot.rows - scroll where !rebuild.contains(row) {
                    // Each source is read once; release it before editing so the row buffer moves without a CoW copy.
                    var moved = rows[row + scroll]
                    rows[row + scroll] = []
                    for index in moved.indices { moved[index].destY -= Float(delta) }
                    rows[row] = moved
                    translated += 1
                }
                for row in ordered {
                    let cells = snapshot.cells(in: row)
                    guard let instances = instances(row: row, cells: cells, geometry: geometry, appearance: appearance,
                                                    cursor: snapshot.cursor) else { return nil }
                    rows[row] = instances
                }
                lastCursorRow = snapshot.cursor.visible ? snapshot.cursor.row : nil
                translatedRowCount = translated; reencodedRowCount = ordered.count
                // Every destination row moved or was exposed, so every row needs an
                // upload even though only `ordered` rows were re-encoded.
                return (Array(0..<snapshot.rows), rows)
            }
        }
        var dirty: [Int]
        if resetAtlas || damage == nil || scroll != 0 {
            dirty = Array(0..<snapshot.rows)
        } else {
            var set = damage ?? []
            // The cursor is drawn over its row, so the row it left also repaints; a hidden cursor only clears.
            if let last = lastCursorRow { set.insert(last) }
            if snapshot.cursor.visible { set.insert(snapshot.cursor.row) }
            dirty = set.filter { (0..<snapshot.rows).contains($0) }.sorted()
        }
        lastCursorRow = snapshot.cursor.visible ? snapshot.cursor.row : nil
        var content: [[TextInstance]] = []
        content.reserveCapacity(dirty.count)
        for row in dirty {
            let cells = snapshot.cells(in: row)
            guard let instances = instances(row: row, cells: cells, geometry: geometry, appearance: appearance,
                                            cursor: snapshot.cursor) else { return nil }
            content.append(instances)
        }
        for (index, row) in dirty.enumerated() where row < rows.count { rows[row] = content[index] }
        reencodedRowCount = dirty.count
        return (dirty, content)
    }

    /// One row's quads in CPU draw order: cell fills, glyphs, then the cursor on top.
    private func instances(row: Int, cells: [Cell], geometry: TextGeometry, appearance: RenderAppearance,
                           cursor: Cursor) -> [TextInstance]? {
        var instances: [TextInstance] = []
        instances.reserveCapacity(cells.count * 4 + 4)
        for cell in cells {
            let selected = cell.selected, search = cell.search
            guard selected || search || cell.bg != appearance.background else { continue }
            let color: (Float, Float, Float)
            if selected { color = deviceColor(appearance.selection) }
            else if cell.activeSearch { color = TextComposer.deviceRGB(0.62, 0.46, 0.12) }
            else if search { color = TextComposer.deviceRGB(0.40, 0.32, 0.10) }
            else { color = deviceColor(cell.bg) }
            let box = geometry.deviceBox(geometry.box(cell))
            instances.append(TextInstance(destX: Float(box.minX), destY: Float(box.minY),
                                          destW: Float(box.width), destH: Float(box.height),
                                          r: color.0, g: color.1, b: color.2))
        }
        // Eligibility refuses every cluster joiner and joinee — a ZWJ tail, a regional indicator, or
        // multi-scalar text — so on an eligible frame GlyphClusters.merge is the identity: each cell is
        // its own Drawn with columns == (cell.wide ? 2 : 1), and a wide spacer is blank and draws nothing.
        // That identity is what lets this loop iterate raw cells instead of merged clusters.
        for cell in cells {
            let text = cell.text
            if text.isEmpty || text == " " || text == "\u{2800}" { continue }
            if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, CellGlyphs.handles(scalar) {
                guard let entry = atlas.entry(scalar: scalar, geometry: geometry) else { return nil }
                let box = geometry.deviceBox(geometry.box(cell)), tile = Float(GlyphAtlas.textureSize)
                let color = deviceColor(cell.fg)
                instances.append(TextInstance(destX: Float(box.minX), destY: Float(box.minY),
                                              destW: Float(box.width), destH: Float(box.height),
                                              u: entry.u, v: entry.v,
                                              uw: Float(entry.width) / tile, uh: Float(entry.height) / tile,
                                              r: color.0, g: color.1, b: color.2))
                continue
            }
            if let scalar = TextEligibility.fittedScalar(cell) {
                let style = UInt8((cell.bold ? 1 : 0) + (cell.italic ? 2 : 0)), fg = cell.fg
                guard let face = faces[safe: Int(style)],
                      let fitted = atlas.fittedEntry(style: style, scalar: scalar, columns: cell.wide ? 2 : 1,
                                                     fg: fg, face: face, geometry: geometry) else { return nil }
                if case .blank = fitted { continue }
                guard case .entry(let entry) = fitted else { return nil }
                let box = geometry.deviceBox(geometry.box(cell))
                let quadX = Float(box.minX) + Float(entry.dx), quadY = Float(box.minY) + Float(entry.dy)
                let quadW = Float(entry.width), quadH = Float(entry.height)
                let left = max(quadX, Float(box.minX)), top = max(quadY, Float(box.minY))
                let right = min(quadX + quadW, Float(box.maxX)), bottom = min(quadY + quadH, Float(box.maxY))
                guard right > left, bottom > top else { continue }
                let tile = Float(GlyphAtlas.textureSize), color = deviceColor(fg)
                instances.append(TextInstance(destX: left, destY: top, destW: right - left, destH: bottom - top,
                                              u: entry.u + (left - quadX) / tile, v: entry.v + (top - quadY) / tile,
                                              uw: (right - left) / tile, uh: (bottom - top) / tile,
                                              r: color.0, g: color.1, b: color.2))
                continue
            }
            let style = UInt8((cell.bold ? 1 : 0) + (cell.italic ? 2 : 0))
            let fg = cell.fg
            guard fg.count == 3, let face = faces[safe: Int(style)],
                  let entry = atlas.entry(style: style, text: text, fg: fg, face: face, geometry: geometry) else { return nil }
            // The rasteriser clips every glyph line to its cell box, so a glyph whose ink overflows (an
            // underscore below the baseline, a wide punctuation mark) must be clipped identically here.
            let origin = geometry.deviceOrigin(cell)
            let box = geometry.deviceBox(geometry.box(cell))
            let quadX = Float(origin.x) + Float(entry.dx), quadY = Float(origin.y) + Float(entry.dy)
            let quadW = Float(entry.width), quadH = Float(entry.height)
            let left = max(quadX, Float(box.minX)), top = max(quadY, Float(box.minY))
            let right = min(quadX + quadW, Float(box.maxX)), bottom = min(quadY + quadH, Float(box.maxY))
            guard right > left, bottom > top else { continue }
            let tile = Float(GlyphAtlas.textureSize)
            let color = deviceColor(fg)
            instances.append(TextInstance(destX: left, destY: top, destW: right - left, destH: bottom - top,
                                          u: entry.u + (left - quadX) / tile, v: entry.v + (top - quadY) / tile,
                                          uw: (right - left) / tile, uh: (bottom - top) / tile,
                                          r: color.0, g: color.1, b: color.2))
        }
        func decoration(_ kind: GlyphAtlas.Decoration, _ cell: Cell, colorBytes: [UInt8]) -> Bool {
            guard let entry = atlas.decorationEntry(kind, geometry: geometry), entry.width == 3 else { return false }
            let box = geometry.deviceBox(geometry.box(cell)), tile = Float(GlyphAtlas.textureSize), color = deviceColor(colorBytes)
            instances.append(TextInstance(destX: Float(box.minX), destY: Float(box.minY), destW: Float(box.width), destH: Float(box.height),
                                          u: entry.u + 1.25 / tile, v: entry.v, uw: 0.5 / tile, uh: Float(entry.height) / tile,
                                          r: color.0, g: color.1, b: color.2))
            return true
        }
        for cell in cells {
            if cell.underline, !decoration(.underline, cell, colorBytes: cell.ucolor ?? cell.fg) { return nil }
            if cell.strike == true, !decoration(.strike, cell, colorBytes: cell.fg) { return nil }
        }
        guard cursor.visible, cursor.row == row else { return instances }
        appendCursor(to: &instances, cursor: cursor, geometry: geometry, appearance: appearance)
        return instances
    }

    /// Cursor quads: the same rectangles the rasterizer fills or strokes, in device pixels.
    private func appendCursor(to instances: inout [TextInstance], cursor: Cursor, geometry: TextGeometry,
                              appearance: RenderAppearance) {
        let width = geometry.cell.width * geometry.scale, height = geometry.cell.height * geometry.scale
        let x = (GridRasterizer.margin + CGFloat(cursor.col) * geometry.cell.width) * geometry.scale
        let y = CGFloat(geometry.height) - (geometry.gridTop - CGFloat(cursor.row) * geometry.cell.height) * geometry.scale
        func fill(_ rect: CGRect, alpha: Float = 1) {
            let color = deviceColor(appearance.cursor)
            instances.append(TextInstance(destX: Float(rect.minX), destY: Float(rect.minY),
                                          destW: Float(rect.width), destH: Float(rect.height),
                                          r: color.0, g: color.1, b: color.2, a: alpha))
        }
        func px(_ originX: CGFloat, _ originY: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: (x + originX * geometry.scale).rounded(), y: (y + originY * geometry.scale).rounded(),
                   width: (w * geometry.scale).rounded(), height: (h * geometry.scale).rounded())
        }
        switch appearance.cursorStyle {
        case .outline:
            // `stroke(box.insetBy(0.5, 0.5))` at width 1 covers one device-pixel-thick band on each edge.
            fill(px(0, 0, geometry.cell.width, 1)); fill(px(0, geometry.cell.height - 1, geometry.cell.width, 1))
            fill(px(0, 0, 1, geometry.cell.height)); fill(px(geometry.cell.width - 1, 0, 1, geometry.cell.height))
        case .block: fill(CGRect(x: x, y: y, width: width, height: height), alpha: 0.55)
        case .bar: fill(px(0, 0, 2, geometry.cell.height))
        case .underline: fill(px(0, geometry.cell.height - 2, geometry.cell.width, 2))
        }
    }

    private func deviceColor(_ bytes: [UInt8]) -> (Float, Float, Float) {
        guard bytes.count == 3 else { return (1, 1, 1) }
        let key = UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
        if let cached = colors[key] { return cached }
        if colors.count >= Self.maxColors { colors.removeAll(keepingCapacity: true) }
        let made = TextComposer.deviceRGB(CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
        colors[key] = made
        return made
    }
    /// Converts a colour exactly as the CPU bitmaps store it, so GPU fills match the software frame's bytes.
    static func deviceRGB(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> (Float, Float, Float) {
        deviceRGB(CGColor(red: red, green: green, blue: blue, alpha: 1))
    }
    static func deviceRGB(_ color: CGColor) -> (Float, Float, Float) {
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.setFillColor(color); context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Float(pixel[2]) / 255, Float(pixel[1]) / 255, Float(pixel[0]) / 255)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
