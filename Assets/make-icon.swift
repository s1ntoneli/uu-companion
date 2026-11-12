import AppKit
import Foundation

// Use the exact image selected by the user, centered without stretching or cropping.
let source = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/app-icon-original.png"
let output = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Assets/uucompanion-1024.png"
guard let image = NSImage(contentsOfFile: source),
      let data = try? Data(contentsOf: URL(fileURLWithPath: source)),
      let sourceRep = NSBitmapImageRep(data: data),
      sourceRep.pixelsWide > 0, sourceRep.pixelsHigh > 0 else {
    fatalError("Missing or invalid app icon source: \(source)")
}
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,
    bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
    colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
    let context = NSGraphicsContext(bitmapImageRep:rep) else {
    fatalError("Cannot allocate icon canvas")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
(sourceRep.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB) ?? NSColor.white).setFill()
NSRect(x:0,y:0,width:size,height:size).fill()
let scale = min(CGFloat(size)/CGFloat(sourceRep.pixelsWide),
                CGFloat(size)/CGFloat(sourceRep.pixelsHigh))
let width = CGFloat(sourceRep.pixelsWide)*scale
let height = CGFloat(sourceRep.pixelsHigh)*scale
image.draw(in:NSRect(x:(CGFloat(size)-width)/2,y:(CGFloat(size)-height)/2,
                     width:width,height:height),
           from:NSRect(origin:.zero,size:image.size),
           operation:.copy,fraction:1)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using:.png,properties:[:]) else {
    fatalError("Cannot encode icon PNG")
}
try png.write(to:URL(fileURLWithPath:output))
print("Rendered user-selected app icon \(size)x\(size): \(output)")
