import AppKit
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("assets/icon-source.png")
guard let image = NSImage(contentsOf: source) else { fatalError("Missing icon source") }
let output = root.appendingPathComponent("build/Akitty.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = points*scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.size = NSSize(width:pixels,height:pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in:NSRect(x:0,y:0,width:pixels,height:pixels),from:.zero,operation:.copy,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
