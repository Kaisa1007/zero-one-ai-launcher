// Builds Resources/AppIcon.icns: Hiden Intelligence logo on a dark terminal tile with a lime hexagon frame.
// usage: swiftc make_icon.swift -o /tmp/make_icon && /tmp/make_icon <Resources dir>
import AppKit

let res = URL(fileURLWithPath: CommandLine.arguments[1])
let logo = NSImage(contentsOf: res.appendingPathComponent("Images/hiden_logo_vec@3x.png"))
    ?? NSImage(contentsOf: res.appendingPathComponent("Images/hiden_logo.png"))!
let lime = NSColor(red: 0.84, green: 0.98, blue: 0.05, alpha: 1)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let S = CGFloat(px)
    let rect = NSRect(x: S * 0.1, y: S * 0.1, width: S * 0.8, height: S * 0.8)
    let tile = NSBezierPath(roundedRect: rect, xRadius: S * 0.18, yRadius: S * 0.18)
    NSGradient(starting: NSColor(red: 0.05, green: 0.08, blue: 0.05, alpha: 1), ending: NSColor(red: 0.01, green: 0.015, blue: 0.01, alpha: 1))!
        .draw(in: tile, angle: -90)
    tile.addClip()
    let c = CGPoint(x: S / 2, y: S / 2)
    let hex = NSBezierPath()
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3
        let p = CGPoint(x: c.x + S * 0.33 * cos(a), y: c.y + S * 0.33 * sin(a))
        i == 0 ? hex.move(to: p) : hex.line(to: p)
    }
    hex.close()
    lime.withAlphaComponent(0.10).setFill(); hex.fill()
    lime.setStroke(); hex.lineWidth = max(1, S * 0.018); hex.stroke()
    let w = S * 0.5, h = w * logo.size.height / logo.size.width
    logo.draw(in: NSRect(x: c.x - w / 2, y: c.y - h / 2 + S * 0.02, width: w, height: h))
    let bar = NSRect(x: c.x - S * 0.12, y: c.y - h / 2 - S * 0.07, width: S * 0.24, height: max(1, S * 0.022))
    lime.setFill(); NSBezierPath(rect: bar).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    for m in [1, 2] {
        let name = m == 1 ? "icon_\(s)x\(s).png" : "icon_\(s)x\(s)@2x.png"
        try! render(s * m).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", res.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
