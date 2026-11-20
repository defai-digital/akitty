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
    let descent: CGFloat
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
    /// Content the atlas cannot draw identically. Kept separate from geometry so the routing decision is a
    /// pure snapshot scan that costs one pass over the cells the frame already carries.
    static func unsupportedContent(_ snapshot: Snapshot, composition: String) -> TextFallback? {
        if !composition.isEmpty { return .composition }
        if !(snapshot.images ?? []).isEmpty { return .images }
        for cell in snapshot.cells {
            if cell.wide { return .wideCell }
            if cell.underline || cell.strike == true { return .decoratedCell }
            let text = cell.text
            if text.utf8.count == 1, let byte = text.utf8.first, (0x20...0x7e).contains(byte) { continue }
            if text.isEmpty { continue }
            if let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1, CellGlyphs.handles(scalar) { continue }
            return .nonASCII
        }
        return nil
    }
    /// The grid geometry the GPU path can place exactly: integral margins, cells and bitmap in device pixels,
    /// and a backing scale the mask rasteriser has been validated at. Fractional scales keep the CPU path.
    static func geometry(size: CGSize, scale: CGFloat, cell: CGSize, fontName: String, fontSize: CGFloat,
                         cols: Int, rows: Int, descent cachedDescent: CGFloat? = nil) -> TextGeometry? {
        guard scale.isFinite, scale == scale.rounded(), (1...3).contains(scale), size.width > 0, size.height > 0 else { return nil }
        func integral(_ value: CGFloat) -> Bool { value.isFinite && value == value.rounded() }
        guard integral(GridRasterizer.margin * scale), integral(cell.width * scale), integral(cell.height * scale),
              integral(size.width * scale), integral(size.height * scale) else { return nil }
        let descent = cachedDescent ?? CTFontGetDescent(CTFontCreateWithName(fontName as CFString, fontSize, nil))
        guard descent.isFinite, descent >= 0 else { return nil }
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        let baseline = descent + 2
        let originX = GridRasterizer.margin * scale
        let originY = CGFloat(height) - (size.height - GridRasterizer.margin - cell.height + baseline) * scale
        func fraction(_ value: CGFloat) -> CGFloat { value - floor(value) }
        return TextGeometry(cols: cols, rows: rows, cell: cell, scale: scale, size: size, width: width, height: height,
                            descent: descent, phaseX: fraction(originX), phaseY: fraction(originY))
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
    private enum Key: Hashable {
        case text(style: UInt8, text: String, fg: UInt32)
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
    /// Coverage for one glyph in one colour, rasterising it the first time it is seen.
    func entry(style: UInt8, text: String, fg: [UInt8], face: CTFont, geometry: TextGeometry) -> Entry? {
        guard fg.count == 3 else { return nil }
        let key = Key.text(style: style, text: text, fg: UInt32(fg[0]) << 16 | UInt32(fg[1]) << 8 | UInt32(fg[2]))
        if let cached = entries[key] { return cached }
        guard entries.count < Self.maxEntries else { exhausted = true; return nil }
        guard let mask = Self.rasterize(text: text, face: face, fg: fg, geometry: geometry) else { return nil }
        return insert(mask, key: key)
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

    private struct Mask { let width: Int, height: Int; let dx: Int, dy: Int; let coverage: [UInt8] }

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
        var cell: CGSize, cols: Int, rows: Int, descent: CGFloat
    }
    /// Colours named by truecolor output are unbounded, exactly as in the rasterizer; convert each once.
    private static let maxColors = 4096
    /// Full atlas rebuilds allowed per font/scale/grid/theme epoch. A truecolor storm that fills the atlas on
    /// every frame would otherwise rasterise the whole window through CoreText each frame, so after this many
    /// rebuilds the path stands down and the CPU rasterizer takes over until the epoch changes.
    static let maxRebuildsPerEpoch = 2
    private static let colorFromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)

    private var faces: [CTFont] = []
    private var base: CTFont?
    private var layout: Layout?
    private let atlas = GlyphAtlas()
    private var rows: [[TextInstance]] = []
    private var colors: [UInt32: (Float, Float, Float)] = [:]
    private var lastCursorRow: Int?
    /// Layout plus appearance: a change re-arms the rebuild budget without invalidating still-valid masks.
    private struct Epoch: Equatable { var layout: Layout; var appearance: RenderAppearance }
    private var epoch: Epoch?
    private var rebuilds = 0
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
        epoch = nil; rebuilds = 0; isSuspended = false
        resetPending = false; recoveryPending = false
        atlas.reset(); atlasEntries = 0; atlasResets = atlas.resets
    }

    /// Builds one frame, or nil when the atlas cannot represent it (the caller then keeps the CPU rasterizer).
    /// Callers that hand off asynchronously defer publication and acknowledge only a successful upload.
    func compose(snapshot: Snapshot, damage: Set<Int>?, size: CGSize, scale: CGFloat, fontName: String, fontSize: CGFloat,
                 cell: CGSize, cjkFontName: String, appearance: RenderAppearance, deferPublication: Bool = false,
                 prevalidated geometry: TextGeometry? = nil, scroll: Int = 0) -> TextFrame? {
        var damage = damage
        guard TextEligibility.unsupportedContent(snapshot, composition: "") == nil else { return nil }
        let cachedDescent = layout.flatMap { $0.fontName == fontName && $0.fontSize == fontSize ? $0.descent : nil }
        let geometry = if let geometry { geometry } else {
            TextEligibility.geometry(size: size, scale: scale, cell: cell, fontName: fontName,
                                     fontSize: fontSize, cols: snapshot.cols, rows: snapshot.rows, descent: cachedDescent)
        }
        guard let geometry else { return nil }
        let wanted = Layout(width: geometry.width, height: geometry.height, scale: scale, fontName: fontName,
                            cjkFontName: cjkFontName, fontSize: fontSize, cell: cell, cols: snapshot.cols,
                            rows: snapshot.rows, descent: geometry.descent)
        let signature = Epoch(layout: wanted, appearance: appearance)
        if epoch != signature { epoch = signature; rebuilds = 0; isSuspended = false; damage = nil }
        if isSuspended { return nil }
        var resetAtlas = resetPending
        if recoveryPending { damage = nil }
        if layout != wanted || base == nil || rows.count != snapshot.rows {
            // A new font, size, scale or grid invalidates every UV and every row.
            layout = wanted
            rebuildFonts(fontName: fontName, fontSize: fontSize, cjkFontName: cjkFontName)
            atlas.reset()
            rows = Array(repeating: [], count: snapshot.rows)
            lastCursorRow = nil
            resetAtlas = true
            resetPending = true
            damage = nil
        }
        recoveryPending = true
        var result = build(snapshot: snapshot, damage: damage, geometry: geometry, appearance: appearance,
                           resetAtlas: resetAtlas, scroll: scroll)
        if result == nil, atlas.exhausted {
            // The atlas filled: recreate it and re-encode everything, up to the per-epoch budget.
            guard rebuilds < Self.maxRebuildsPerEpoch else {
                isSuspended = true; atlasEntries = atlas.count; atlasResets = atlas.resets; return nil
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

    func acknowledgePublication() {
        atlas.clearPending()
        resetPending = false; recoveryPending = false
    }

    private func rebuildFonts(fontName: String, fontSize: CGFloat, cjkFontName: String) {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        base = font
        let languages = Locale.preferredLanguages
        faces = [font,
                 CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .boldTrait, .boldTrait) ?? font,
                 CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .italicTrait, .italicTrait) ?? font,
                 CTFontCreateCopyWithSymbolicTraits(font, 0, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]) ?? font]
            .map { GlyphFonts.cascadeFont(base: $0, cjkFontName: cjkFontName, languages: languages) }
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
        instances.reserveCapacity(cells.count * 2 + 4)
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
        // Eligibility excludes emoji clusters, so every remaining cell draws independently in its own box.
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
