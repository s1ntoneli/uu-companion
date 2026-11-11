import AppKit

// Reproducible, dependency-free light macOS icon for uu伴侣.
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/uucompanion-1024.png"
let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Cannot create icon canvas")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a)
}
func round(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x:x, y:y, width:w, height:h), xRadius:radius, yRadius:radius)
}
func fill(_ path: NSBezierPath, _ color: NSColor) {
    color.setFill()
    path.fill()
}
func gradient(_ path: NSBezierPath, _ start: NSColor, _ end: NSColor, angle: CGFloat = 0) {
    NSGradient(starting:start, ending:end)!.draw(in:path, angle:angle)
}
func softShadow(blur: CGFloat, alpha: CGFloat, dy: CGFloat = -10) {
    let shadow = NSShadow()
    shadow.shadowColor = c(69,65,122,alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width:0,height:dy)
    shadow.set()
}

// Quiet rounded tile, with air around the illustration.
let tile = round(52, 56, 920, 912, 214)
NSGraphicsContext.saveGraphicsState()
softShadow(blur:27, alpha: 0.12, dy:-16)
fill(tile, c(253,253,255))
NSGraphicsContext.restoreGraphicsState()
fill(round(74,81,875,867,192), c(251,250,255,0.42))

// The second Mac: a small friendly blue device behind the microphone Mac.
NSGraphicsContext.saveGraphicsState()
softShadow(blur:20, alpha:0.16)
fill(round(501,389,370,346,60), .white)
NSGraphicsContext.restoreGraphicsState()
gradient(round(520,420,332,280,43), c(91,183,249), c(64,115,245), angle:-35)
let letters: NSString = "uu"
letters.draw(at:NSPoint(x:609,y:519),withAttributes:[
    .font:NSFont.systemFont(ofSize:127,weight:.heavy),
    .foregroundColor:NSColor.white
])
fill(round(478,379,413,49,25), c(240,242,254))
fill(round(613,407,136,9,4), c(188,195,245,0.6))

// The foreground purple mic device, with a very soft raised white bezel.
NSGraphicsContext.saveGraphicsState()
softShadow(blur:22, alpha:0.15, dy:-14)
fill(round(191,214,556,474,67), .white)
NSGraphicsContext.restoreGraphicsState()
gradient(round(213,241,512,424,48), c(174,145,252), c(119,102,246), angle:-37)

// Mic capsule, curved cradle, stem, and subtle radio wave.
fill(round(428,429,78,151,39), .white)
let cradle=NSBezierPath()
cradle.lineWidth=18
cradle.lineCapStyle = .round
cradle.move(to:NSPoint(x:389,y:486))
cradle.curve(to:NSPoint(x:467,y:405),controlPoint1:NSPoint(x:389,y:436),controlPoint2:NSPoint(x:420,y:405))
cradle.curve(to:NSPoint(x:545,y:486),controlPoint1:NSPoint(x:514,y:405),controlPoint2:NSPoint(x:545,y:436))
NSColor.white.setStroke()
cradle.stroke()
let stem=NSBezierPath()
stem.lineWidth=17
stem.lineCapStyle = .round
stem.move(to:NSPoint(x:467,y:407))
stem.line(to:NSPoint(x:467,y:363))
stem.move(to:NSPoint(x:428,y:362))
stem.line(to:NSPoint(x:506,y:362))
stem.stroke()
for (x, y, k) in [(572.0,474.0,0.0),(597.0,457.0,0.1)] {
    let wave=NSBezierPath()
    wave.lineWidth=16
    wave.lineCapStyle = .round
    wave.move(to:NSPoint(x:x,y:y))
    wave.curve(to:NSPoint(x:x,y:y+92),controlPoint1:NSPoint(x:x+49+k,y:y+20),controlPoint2:NSPoint(x:x+49+k,y:y+69))
    wave.stroke()
}

// Tiny voice strokes to give the icon a playful, distinctive personality.
for (x,y,angle) in [(309.0,729.0,27.0),(369.0,756.0,13.0),(440.0,762.0,-2.0)] {
    let path=round(CGFloat(x),CGFloat(y),23,62,12)
    NSGraphicsContext.saveGraphicsState()
    let t=NSAffineTransform()
    t.translateX(by:CGFloat(x+11),yBy:CGFloat(y+31))
    t.rotate(byDegrees:CGFloat(angle))
    t.translateX(by:CGFloat(-x-11),yBy:CGFloat(-y-31))
    t.concat()
    fill(path,c(158,135,247))
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.saveGraphicsState()
softShadow(blur:15,alpha:0.1,dy:-6)
fill(round(163,205,617,62,31),c(240,236,255))
NSGraphicsContext.restoreGraphicsState()
fill(round(169,220,605,43,22),c(252,249,255))
fill(round(377,246,180,9,5),c(185,165,242,0.5))

NSGraphicsContext.restoreGraphicsState()
guard let data=bitmap.representation(using:.png,properties:[:]) else {
    fatalError("Cannot encode icon PNG")
}
try data.write(to:URL(fileURLWithPath:output))
print("Rendered \(output)")
