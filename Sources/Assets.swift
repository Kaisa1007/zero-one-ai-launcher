import AppKit
import ImageIO

enum KeyID: String, CaseIterable, Codable {
    case risingHopper, metalClusterHopper

    var displayName: String { self == .risingHopper ? "Rising Hopper" : "Metal Cluster Hopper" }
    var filePrefix: String { self == .risingHopper ? "rising_hopper" : "metal_cluster_hopper" }
    var other: KeyID { self == .risingHopper ? .metalClusterHopper : .risingHopper }
    var accent: NSColor {
        self == .risingHopper ? NSColor(red: 0.84, green: 0.98, blue: 0.05, alpha: 1)
                              : NSColor(red: 0.70, green: 0.86, blue: 1.0, alpha: 1)
    }
    var activateClip: String { self == .risingHopper ? "rh_activate" : "mch_activate" }
    /// Both keys use the common authorise clip in the SWF (447 f7, 699 f9).
    var authorizeClip: String { "authorize_common" }
    var henshinClip: String { self == .risingHopper ? "rh_henshin" : "mch_henshin" }
}

struct ClipInfo: Decodable {
    let id: String
    let file: String
    let play_start_frame: Int
    let play_frame_count: Int
    let play_duration_s: Double
    let audible_end_s: Double
    /// Voice lines: end of the words (before the reverb tail).
    let speech_end_s: Double?
}

/// Per-key geometry measured at build time (canvas px at 1x).
struct KeySpec: Decodable {
    struct Overlay: Decodable {
        let frames: Int
        let canvas_offset: [CGFloat]
        let flip_frames: [Int]
        let flip_sound_frame: Int
        let metal_rise_frame: Int
    }
    let frames: Int
    let canvas_offset: [CGFloat]
    let closed_bbox: [CGFloat]
    let open_bbox: [CGFloat]
    let docked_bbox: [CGFloat]?
    let overlay: Overlay?

    var canvasOffset: CGPoint { CGPoint(x: canvas_offset[0], y: canvas_offset[1]) }
    var closedBBox: CGRect { rect(closed_bbox) }
    var openBBox: CGRect { rect(open_bbox) }
    var dockedBBox: CGRect { docked_bbox.map(rect) ?? openBBox }
    private func rect(_ a: [CGFloat]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }

    static let fallback = KeySpec(frames: 13, canvas_offset: [0, -140.05], closed_bbox: [0, 141, 239, 154],
                                  open_bbox: [9, 141, 413, 155], docked_bbox: nil, overlay: nil)
}

struct SequenceInfo: Decodable {
    let frames: [Int]
    let fps: Double
    let canvas_1x: [CGFloat]
    let scale: CGFloat
}

private struct Manifest: Decodable {
    struct Image: Decodable { let name: String; let file: String }
    let images: [Image]
    let audio: [ClipInfo]
    let keys: [String: KeySpec]?
    let sequences: [String: SequenceInfo]?
}

/// Loads everything from the app bundle's Resources (no absolute paths to the asset library).
final class AssetStore {
    static let zoom: CGFloat = 3
    let resourceURL: URL
    private(set) var images: [String: CGImage] = [:]
    private(set) var clips: [String: ClipInfo] = [:]
    private(set) var keySpecs: [KeyID: KeySpec] = [:]
    private(set) var sequences: [String: SequenceInfo] = [:]
    private(set) var missing: [String] = []
    private(set) var decodeTime = 0.0

    /// Redraws an image into a premultiplied BGRA bitmap, the format Core Animation uploads without conversion.
    static func native(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
    /// After the handoff the launcher stays in the background (re-skinning new Codex windows): drop the bitmaps.
    func purgeImages() { images.removeAll() }

    init(bundle: Bundle = .main) {
        resourceURL = bundle.resourceURL ?? URL(fileURLWithPath: ".")
        let manifestURL = resourceURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            missing.append("manifest.json")
            return
        }
        // Decode every image up front, in parallel, into Core Animation's native pixel format (premultiplied BGRA).
        // Otherwise a PNG is decoded on the main thread the first time it appears (the 24 wipe frames alone are
        // ~250 MB decoded), which made the AUTHORIZE card stutter.
        let t0 = CACurrentMediaTime()
        let list = m.images
        var decoded = [CGImage?](repeating: nil, count: list.count)
        let lock = NSLock()
        let base = resourceURL
        DispatchQueue.concurrentPerform(iterations: list.count) { k in
            let url = base.appendingPathComponent(list[k].file)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
            let out = AssetStore.native(img) ?? img
            lock.lock(); decoded[k] = out; lock.unlock()
        }
        for (k, i) in list.enumerated() {
            if let img = decoded[k] { images[i.name] = img } else { missing.append(i.file) }
        }
        decodeTime = CACurrentMediaTime() - t0
        for c in m.audio { clips[c.id] = c }
        for (k, v) in m.keys ?? [:] { if let id = KeyID(rawValue: k) { keySpecs[id] = v } }
        sequences = m.sequences ?? [:]
        Geo.specs = keySpecs
    }

    func image(_ name: String) -> CGImage? { images[name] }
    func keyFrame(_ key: KeyID, _ n: Int) -> CGImage? { images[String(format: "%@_f%02d", key.filePrefix, n)] }
    func keyFrames(_ key: KeyID) -> [CGImage] { (1...Geo.spec(key).frames).compactMap { keyFrame(key, $0) } }
    func dockedImage(_ key: KeyID) -> CGImage? { images["\(key.filePrefix)_docked"] }
    func overlayFrame(_ key: KeyID, _ n: Int) -> CGImage? { images[String(format: "%@_over_f%02d", key.filePrefix, n)] }
    func sequenceFrames(_ name: String) -> [CGImage] {
        guard let s = sequences[name] else { return [] }
        return (s.frames[0]...s.frames[1]).compactMap { images[String(format: "%@_f%02d", name, $0)] }
    }
    /// Size in 1x points of an image rendered at `scale`.
    func size(_ img: CGImage, scale: CGFloat = AssetStore.zoom) -> CGSize {
        CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
    }
    func url(for clip: ClipInfo) -> URL { resourceURL.appendingPathComponent(clip.file) }
}
