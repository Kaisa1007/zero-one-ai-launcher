import CoreGraphics

/// All coordinates below are in "driver space": SWF sprite 2043 (the Zero-One Driver)
/// in 1x pixels, y pointing down. Numbers come from the SWF PlaceObject matrices
/// (twips / 20) and from the FFDec canvas offsets of each exported layer.
enum Geo {
    static let fps: Double = 30
    static let frame: Double = 1 / fps

    // Stage (window content is scaled to fit this logical size).
    static let stageSize = CGSize(width: 1280, height: 800)
    /// Stage points per driver pixel. Images are 3x, so this stays sharp on Retina up to ~1.25x window scale.
    static let driverScale: CGFloat = 1.2
    static let driverOrigin = CGPoint(x: 277.8, y: 405)
    static let driverRect = CGRect(x: 0, y: 0, width: 604, height: 276)

    // Layers inside sprite 2043.
    static let baseOrigin = CGPoint(x: 0, y: 1.25)          // shape 1958, depth 189
    static let coreOrigin = CGPoint(x: 241.5, y: 46.7)      // shape 430, depth 5
    static let coreCenter = CGPoint(x: 331.9, y: 138.35)
    /// Liberator (sprite 1964 placed at x 325.2) holding the cover shape 1959.
    static let coverClosedX: CGFloat = 133.4                // 325.2 - 191.8
    static let coverOpenX: CGFloat = 325.2
    /// Sprite 1964 frames 4-7 ("ZO Driver Liberator Henshin"): one step per frame.
    static let coverOpenSteps: [CGFloat] = [181.35, 229.3, 277.25, 325.2]
    static let coverCloseSteps: [CGFloat] = [277.25, 229.3, 181.35, 133.4]

    /// Authorise area: the driver's left lobe (where SWF "PK Movement Scan" happens).
    static let authCenter = CGPoint(x: 130, y: 138)
    static let authRadius: CGFloat = 118
    static let authDropRadius: CGFloat = 190

    // Keys (sprites 471 / 710): canvas offsets and bounding boxes are measured at build time (manifest "keys").
    static var specs: [KeyID: KeySpec] = [:]
    static func spec(_ k: KeyID) -> KeySpec { specs[k] ?? .fallback }
    static func canvasOffset(_ k: KeyID) -> CGPoint { spec(k).canvasOffset }
    /// Key art centre in sprite coordinates (closed key).
    static func keyArtCenter(_ k: KeyID) -> CGPoint {
        let b = spec(k).closedBBox, o = canvasOffset(k)
        return CGPoint(x: b.midX + o.x, y: b.midY + o.y)
    }
    /// Sprite 1957 "Progrises" is placed at (-470, 944) twips in 2043; key sprite sits at its origin.
    static let progrisesOrigin = CGPoint(x: -23.5, y: 47.2)

    static func fm(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ txTw: CGFloat, _ tyTw: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: txTw / 20, ty: tyTw / 20)
    }
    static func tx(_ tw: CGFloat) -> CGAffineTransform { CGAffineTransform(translationX: tw / 20, y: 0) }

    // Diagonal authorise insert: the key tilts to the SWF swing's end angle (1957 f10, 35.5 deg)
    // and slides along its own long axis until its front end sits on the reader button.
    /// Centre of the authoriser button on the driver's left lobe (yellow ring + grey cylinder).
    static let readerPoint = CGPoint(x: 132, y: 136)
    static let scanAngle: CGFloat = atan2(0.58032227, 0.81437683)
    /// Distance along the key's axis from its art centre to the point that meets the reader (sprite x = 200,
    /// the front end of both key bodies).
    static func scanLead(_ k: KeyID) -> CGFloat { 200 - keyArtCenter(k).x }
    /// Depths (px along the insert direction; 0 = contact). Approach, 5 frames in, push/settle, 5 frames out.
    static let scanApproachDepth: CGFloat = -120
    static let scanInDepths: [CGFloat] = [-104, -82, -54, -22, 6]
    static let scanSettleDepths: [CGFloat] = [-2, 0]
    static let scanOutDepths: [CGFloat] = [-14, -38, -66, -92, -110]

    static func pose(_ k: KeyID, center: CGPoint, angle: CGFloat, scale: CGFloat = 1) -> CGAffineTransform {
        let c = keyArtCenter(k)
        return CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }
    static func diagonalPose(_ key: KeyID, depth: CGFloat) -> CGAffineTransform {
        let k = depth - scanLead(key)
        return pose(key, center: CGPoint(x: readerPoint.x + k * cos(scanAngle), y: readerPoint.y + k * sin(scanAngle)), angle: scanAngle)
    }
    /// (centre, angle, scale) of a key pose, for blending during drag.
    static func decompose(_ k: KeyID, _ m: CGAffineTransform) -> (center: CGPoint, angle: CGFloat, scale: CGFloat) {
        (keyArtCenter(k).applying(m), atan2(m.b, m.a), hypot(m.a, m.b))
    }

    /// Sprite 1957 frames 6...10 / 30...36 as in the SWF (kept for reference; the app now uses the
    /// diagonal insert above, which ends at the same angle as frame 10).
    static let swfScanDown: [CGAffineTransform] = [
        fm(0.99209595, 0.122283936, -0.122283936, 0.99209595, -742, 813),
        fm(0.9692993, 0.24272156, -0.24272156, 0.9692993, -1423, 1658),
        fm(0.9307556, 0.36257935, -0.36257935, 0.9307556, -2040, 2531),
        fm(0.8790741, 0.47381592, -0.47381592, 0.8790741, -2614, 3462),
        fm(0.81437683, 0.58032227, -0.58032227, 0.81437683, -3143, 4435),
    ]
    static let swfScanUp: [CGAffineTransform] = [
        fm(0.8618164, 0.504364, -0.504364, 0.8618164, -2771, 3738),
        fm(0.90286255, 0.4269104, -0.4269104, 0.90286255, -2375, 3058),
        fm(0.9370117, 0.3461914, -0.3461914, 0.9370117, -1955, 2403),
        fm(0.9648285, 0.25967407, -0.25967407, 0.9648285, -1516, 1781),
        fm(0.98410034, 0.17422485, -0.17422485, 0.98410034, -1041, 1171),
        fm(0.99586487, 0.08744812, -0.08744812, 0.99586487, -538, 579),
        .identity,
    ]
    /// Frames 38-44 "PK Movement To Out", 45-49 "Driver To On".
    static let toOut: [CGFloat] = [-1892, -3784, -5676, -7568, -9460, -11352, -13244].map { $0 / 20 }
    static let driverToOn: [CGFloat] = [-13720, -12250, -10780, -9310, -7840].map { $0 / 20 }
    /// Waiting position left of the slot. SWF uses -392 for every key; Metal Cluster Hopper's grip makes it
    /// ~276 px longer, so it waits partly behind the base (still behind it, so nothing pops).
    static func readyX(_ k: KeyID) -> CGFloat { spec(k).overlay == nil ? -392 : -300 }
    static func driverToOn(_ k: KeyID) -> [CGFloat] { driverToOn.map { $0 - driverToOn.last! + readyX(k) } }
    /// Frames 52-59 "PK Movement To In" and 61-64 "PK Movement Finish" (settle bump).
    static let toIn: [CGFloat] = [-6640, -5440, -4240, -3040, -1840, -640, 560, 15].map { $0 / 20 }
    static let finishBump: [CGFloat] = [0, 280, 148, 15].map { $0 / 20 }
    static let insertedX: CGFloat = 0.75
    /// Frames 66-71 "PK Movement Remove" (x, alpha).
    static let remove: [(CGFloat, Float)] = [(-1481, 213), (-2977, 171), (-4473, 128), (-5968, 85), (-7464, 43), (-8960, 0)]
        .map { ($0.0 / 20, $0.1 / 256) }

    // Event timing taken from the SWF frame scripts (see README):
    /// 1957 f10 plays the scan sound, f29 (19 frames later) the key's authorise voice.
    static let authorizeAfterScan: Double = 19 * frame
    /// 1957 f36 starts the flip, 26 frames after the scan sound.
    static let flipAfterScan: Double = 26 * frame
    /// 376 f51 starts the standby loop, 48 frames after the scan sound (f3).
    static let standbyAfterScan: Double = 48 * frame
    /// 471 f26 -> f27 plays the Progrise trigger two frames after insertion.
    static let progriseAfterInsert: Double = 2 * frame
    /// 408 f7 plays 406, f95 starts the key's henshin voice: 88 frames.
    static let henshinAfterProgrise: Double = 88 * frame

    /// Key pose (sprite -> driver space) for a 1957 matrix.
    static func progrisePose(_ m: CGAffineTransform) -> CGAffineTransform {
        m.concatenating(CGAffineTransform(translationX: progrisesOrigin.x, y: progrisesOrigin.y))
    }
    static func slotPose(x: CGFloat) -> CGAffineTransform { progrisePose(CGAffineTransform(translationX: x, y: 0)) }
    /// Layer transform for a key pose (canvas -> driver space).
    static func layerTransform(_ pose: CGAffineTransform, _ k: KeyID) -> CGAffineTransform {
        let o = canvasOffset(k)
        return CGAffineTransform(translationX: o.x, y: o.y).concatenating(pose)
    }
    /// Front overlay (sprite 1973) shares the key's sprite origin (1976 at -469 vs 1957 at -470 tw).
    static func overlayTransform(_ pose: CGAffineTransform, _ k: KeyID) -> CGAffineTransform {
        guard let o = spec(k).overlay else { return layerTransform(pose, k) }
        return CGAffineTransform(translationX: o.canvas_offset[0], y: o.canvas_offset[1]).concatenating(pose)
    }
    /// Bounding box (driver space) of a key's canvas box under a pose.
    static func keyBox(_ k: KeyID, _ pose: CGAffineTransform, _ box: CGRect) -> CGRect {
        box.applying(layerTransform(pose, k))
    }

    /// Rack position: closed key centred at a stage point, same scale as the driver.
    static func rackPose(_ k: KeyID, stageCenter: CGPoint, lift: CGFloat = 0, scale: CGFloat = 1) -> CGAffineTransform {
        let target = CGPoint(x: (stageCenter.x - driverOrigin.x) / driverScale,
                             y: (stageCenter.y - lift - driverOrigin.y) / driverScale)
        let c = keyArtCenter(k)
        return CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: target.x, y: target.y))
    }
    static let rackCenters: [KeyID: CGPoint] = [.risingHopper: CGPoint(x: 372, y: 214), .metalClusterHopper: CGPoint(x: 906, y: 214)]

    // Camera: driverSpace origin + zoom. Home = the normal layout.
    struct Camera: Equatable { var origin: CGPoint; var zoom: CGFloat }
    static let home = Camera(origin: driverOrigin, zoom: driverScale)
    /// Keeps the driver and the given boxes (driver space) on stage; stays at home when they already fit.
    static func fit(_ boxes: [CGRect], margin: CGFloat = 28) -> Camera {
        let u = boxes.reduce(driverRect) { $0.union($1) }
        let left = home.origin.x + u.minX * home.zoom, right = home.origin.x + u.maxX * home.zoom
        if left >= margin && right <= stageSize.width - margin { return home }
        let zoom = min(driverScale, (stageSize.width - 2 * margin) / u.width, (stageSize.height - 2 * margin) / u.height)
        let x = margin + ((stageSize.width - 2 * margin) - u.width * zoom) / 2 - u.minX * zoom
        let centreY = home.origin.y + driverRect.midY * home.zoom
        var y = centreY - driverRect.midY * zoom
        y = min(max(y, margin - u.minY * zoom), stageSize.height - margin - u.maxY * zoom)
        return Camera(origin: CGPoint(x: x, y: y), zoom: zoom)
    }
}
