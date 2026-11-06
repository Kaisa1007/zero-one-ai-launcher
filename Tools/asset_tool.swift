// Build-time helper used by prepare_assets.py (never shipped in the app).
//   asset_tool compose <out.png> <W> <H> <img> <x> <y> [<img> <x> <y> ...]   (pixel coords, y down, drawn in order)
//   asset_tool bbox <img.png>                                                (alpha > 8 bounding box: x y w h, pixels)
//   asset_tool diff <a.png> <b.png>                                          (mean / max abs channel difference)
import AppKit

func load(_ p: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("cannot read \(p)") }
    return img
}

func rgba(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return buf
}

let a = CommandLine.arguments
switch a[1] {
case "compose":
    let w = Int(a[3])!, h = Int(a[4])!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    var i = 5
    while i + 2 < a.count + 0 && i < a.count {
        let img = load(a[i]); let x = Double(a[i + 1])!, y = Double(a[i + 2])!
        // CG is y-up: convert the top-left placement.
        ctx.draw(img, in: CGRect(x: x, y: Double(h) - y - Double(img.height), width: Double(img.width), height: Double(img.height)))
        i += 3
    }
    let out = ctx.makeImage()!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, out, nil); CGImageDestinationFinalize(dst)
case "bbox":
    let img = load(a[2]); let w = img.width, h = img.height
    let b = rgba(img, w, h)
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h { for x in 0..<w where b[(y * w + x) * 4 + 3] > 8 {
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
    } }
    print(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
case "diff":
    let ia = load(a[2]), ib = load(a[3])
    let w = max(ia.width, ib.width), h = max(ia.height, ib.height)
    let pa = rgba(ia, w, h), pb = rgba(ib, w, h)
    var sum = 0.0, mx = 0, big = 0
    for i in 0..<pa.count { let d = abs(Int(pa[i]) - Int(pb[i])); sum += Double(d); mx = max(mx, d); if d > 32 { big += 1 } }
    print(String(format: "mean %.3f max %d pixels>32: %.4f%%", sum / Double(pa.count), mx, Double(big) / Double(pa.count) * 100))
case "crop":   // crop <in> <out> <x> <y> <w> <h>   (pixels, top-left origin)
    let img = load(a[2])
    let r = CGRect(x: Int(a[4])!, y: Int(a[5])!, width: Int(a[6])!, height: Int(a[7])!)
    let out = img.cropping(to: r)!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, out, nil); CGImageDestinationFinalize(dst)
case "figure": // figure <in> <out> <minAlpha 0-1> <x0 frac> <x1 frac>
    // Keeps opaque pixels (alpha >= minAlpha) of the largest connected region inside [x0, x1): removes the
    // translucent sheet panel and stray marks, then crops to the figure. No resampling.
    let img = load(a[2]); let w = img.width, h = img.height
    var b = rgba(img, w, h)
    let th = UInt8(Double(a[4])! * 255), x0 = Int(Double(a[5])! * Double(w)), x1 = Int(Double(a[6])! * Double(w))
    var keep = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in x0..<x1 where b[(y * w + x) * 4 + 3] >= th { keep[y * w + x] = true } }
    var label = [Int32](repeating: 0, count: w * h); var best = (id: Int32(0), size: 0); var next: Int32 = 1
    for start in 0..<(w * h) where keep[start] && label[start] == 0 {
        var stack = [start]; label[start] = next; var size = 0
        while let i = stack.popLast() {
            size += 1
            let x = i % w, y = i / w
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                if keep[j] && label[j] == 0 { label[j] = next; stack.append(j) }
            } }
        }
        if size > best.size { best = (next, size) }
        next += 1
    }
    var minX = w, minY = h, maxX = 0, maxY = 0
    for i in 0..<(w * h) {
        if label[i] == best.id { let x = i % w, y = i / w; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        else { b[i * 4] = 0; b[i * 4 + 1] = 0; b[i * 4 + 2] = 0; b[i * 4 + 3] = 0 }
    }
    let ctx = CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let out = ctx.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, out, nil); CGImageDestinationFinalize(dst)
    print(minX, minY, maxX - minX + 1, maxY - minY + 1, best.size)
default: fatalError("unknown command")
}
