import AppKit
import QuartzCore

/// Layout of the boot sequence: a 1600 x 1000 canvas (16:10, y down) scaled to fit the screen.
/// The look is a login to the Hiden Intelligence corporate system; text is mainly Japanese / kanji.
enum Boot {
    static let canvas = CGSize(width: 1600, height: 1000)
    static let center = CGPoint(x: 800, y: 480)
    static let ringRadius: CGFloat = 190
    static let lime = NSColor(red: 0.84, green: 0.98, blue: 0.05, alpha: 1)
    static let red = NSColor(red: 0.96, green: 0.16, blue: 0.20, alpha: 1)
    static let ink = NSColor(red: 0.012, green: 0.018, blue: 0.014, alpha: 1)
    /// Login panel and its fingerprint window.
    static let panel = CGRect(x: 300, y: 230, width: 1000, height: 500)
    static let scanFrame = CGRect(x: 900, y: 300, width: 340, height: 360)
    /// Centre of the Hiden logo in the final sequence.
    static let logoCenter = CGPoint(x: 800, y: 390)
    static let authorizeClip = "authorize_common"
}

enum PanelState { case off, blink, on }
enum CardStyle { case limeWipe, black }

/// Every Core Animation animation in the launcher (explicit and implicit) runs at 60 fps. On a 120 Hz ProMotion
/// screen they would otherwise run at 120 fps, out of step with the 60 fps timer-driven parts (sync ring, clock,
/// hex transition). Done once by exchanging CALayer.add(_:forKey:) with a version that sets the frame rate.
extension CALayer {
    @objc fileprivate func zo_add60(_ anim: CAAnimation, forKey key: String?) {
        // Implicit animations arrive read-only, so the frame rate is set on a copy (the layer copies it anyway).
        let r = CAFrameRateRange(minimum: BootStage.fps, maximum: BootStage.fps, preferred: BootStage.fps)
        guard let a = anim.copy() as? CAAnimation else { zo_add60(anim, forKey: key); return }
        a.preferredFrameRateRange = r
        if let g = a as? CAAnimationGroup {
            g.animations = g.animations?.map { sub in
                guard let c = sub.copy() as? CAAnimation else { return sub }
                c.preferredFrameRateRange = r; return c
            }
        }
        zo_add60(a, forKey: key)   // the original implementation (methods are exchanged)
    }
    static let lockAnimationsTo60: Void = {
        guard let a = class_getInstanceMethod(CALayer.self, #selector(CALayer.add(_:forKey:))),
              let b = class_getInstanceMethod(CALayer.self, #selector(CALayer.zo_add60(_:forKey:))) else { return }
        method_exchangeImplementations(a, b)
    }()
}

/// Deterministic pseudo-random numbers, so every boot (and every snapshot) looks the same.
struct Seeded {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> CGFloat {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((s >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}

/// The Core Animation stage of the boot animation. All flipping is done with explicit transforms (no
/// geometryFlipped), so snapshots via render(in:) match the screen.
final class BootStage: NSView {
    let assets: AssetStore
    private let root = CALayer()
    let stage = CALayer()
    private var cardToken = 0
    private var started = CACurrentMediaTime()
    private var clockOn = false
    private var timers: [Timer] = []
    // Display-synchronised frame clock (60 fps = every 2nd refresh on the 120 Hz screen): every per-frame update
    // (sync ring, clock, match counter, hex transition) runs from it, in step with Core Animation.
    static let fps: Float = 60
    private var link: CADisplayLink?
    private var frameHandlers: [String: (CFTimeInterval) -> Void] = [:]
    /// Frame-time monitor: intervals between frames per phase (the director names the phases).
    var perfPhase = "boot"
    private var perfLast: CFTimeInterval = 0
    private(set) var perfFrames: [String: [Double]] = [:]
    private(set) var perfOrder: [String] = []

    // background / chrome
    private var hexBG = CALayer()
    private let crt = CALayer(), flash = CALayer()
    private let rainL = CATextLayer(), rainR = CATextLayer()
    private let hud = CALayer(), corners = CAShapeLayer(), timecode = CATextLayer()
    private var hexPanels: [(shape: CAShapeLayer, label: CATextLayer, text: String, state: PanelState)] = []
    private let log = CATextLayer(), status = CATextLayer()
    private var logLines: [String] = []
    // splash
    private let splash = CALayer(), splashLogo = CALayer(), splashJP = CATextLayer(), splashSub = CATextLayer()
    private let splashBar = CALayer(), splashBarFill = CALayer()
    // login panel
    private let login = CALayer(), loginFrame = CAShapeLayer()
    private var fieldValues: [CATextLayer] = []
    private let authLine = CATextLayer()
    private let fpBase = CAShapeLayer(), fpLit = CAShapeLayer(), fpMask = CAGradientLayer()
    private var fpDots: [CAShapeLayer] = []
    private let fpMatch = CATextLayer(), scanBeam = CALayer(), scanLabel = CATextLayer()
    private let fpTip = CAShapeLayer(), fpNet = CAShapeLayer(), loginBloom = CAShapeLayer()
    private var fpRunners: [CALayer] = [], fpRings: [CGPath] = [], fpPoints: [CGPoint] = []
    // sync ring + ZEA
    private let ring = CALayer(), ringArc = CAShapeLayer(), ringValue = CATextLayer()
    private var ringGlow: [CAShapeLayer] = []
    private let satellite = CALayer(), orbit = CAShapeLayer()
    private let syncBeam = CAShapeLayer(), beamHit = CALayer()
    private var flowDots: [CALayer] = [], flowIndex = 0, panelCenters: [CGPoint] = []
    private var flowTimer: Timer?
    // Hiden logo finale
    private let finale = CALayer(), core = CALayer()
    private var centerLight = CALayer()
    private var fragments: [CALayer] = []
    private var streaks: [CALayer] = []
    private var shocks: [CAShapeLayer] = []
    private let logoGroup = CALayer(), logoHost = CALayer(), sweepHost = CALayer(), sweepBand = CAGradientLayer()
    private var chromaA = CALayer(), chromaB = CALayer()
    private let holo = CAReplicatorLayer(), holoHost = CALayer(), stampRing = CAShapeLayer()
    private var logoSlices: [CALayer] = []
    private let logoJP = CATextLayer(), grantJP = CATextLayer(), welcome = CATextLayer(), logoEN = CATextLayer(), logoRules = CAShapeLayer()
    private let emitter = CAEmitterLayer()
    // cards
    private let cards = CALayer()
    private let wipe = CALayer(), wipeMask = CAGradientLayer()
    private let cardTitle = CATextLayer(), cardSub = CATextLayer(), cardTag = CATextLayer(), cardRules = CAShapeLayer()

    init(assets: AssetStore) {
        _ = CALayer.lockAnimationsTo60
        self.assets = assets
        super.init(frame: NSRect(origin: .zero, size: Boot.canvas))
        layer = root
        wantsLayer = true
        root.backgroundColor = NSColor.black.cgColor
        build()
        // Render the AUTHORIZE card's big type before the window is even shown (costs no animation frames later).
        prepareCard("認証", sub: "AUTHORIZE", tag: "飛電インテリジェンス　社長認証", style: .limeWipe)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Helpers

    static func upright(_ h: CGFloat) -> CGAffineTransform { CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h) }

    private func image(_ l: CALayer, _ img: CGImage?, frame: CGRect) {
        l.contents = img; l.contentsGravity = .resize; l.minificationFilter = .trilinear
        l.anchorPoint = .zero
        l.bounds = CGRect(origin: .zero, size: frame.size)
        l.position = frame.origin
        l.setAffineTransform(Self.upright(frame.height))
    }

    /// Largest size (canvas points) an image may be shown at while keeping >= 2 px per point, i.e. never
    /// upscaled on a Retina screen (the canvas is roughly 1:1 with screen points).
    private func crisp(_ name: String, maxW: CGFloat = .greatestFiniteMagnitude, maxH: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        guard let i = assets.image(name) else { return .zero }
        let s = assets.size(i, scale: 2)
        let k = min(1, maxW / s.width, maxH / s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }
    private var logoName: String { assets.image("hiden_logo_vec") != nil ? "hiden_logo_vec" : "hiden_logo" }

    private func tintedLayer(_ img: CGImage?, size: CGSize, center: CGPoint, color: NSColor = Boot.lime, mask: inout CALayer) -> CALayer {
        let t = CALayer()
        t.bounds = CGRect(origin: .zero, size: size); t.position = center
        t.backgroundColor = color.cgColor
        let m = CALayer()
        m.anchorPoint = .zero; m.bounds = t.bounds; m.position = .zero
        m.contents = img; m.contentsGravity = .resize
        m.setAffineTransform(Self.upright(size.height))
        t.mask = m
        mask = m
        return t
    }
    private func tinted(_ name: String, size: CGFloat, center: CGPoint) -> CALayer {
        var m = CALayer()
        return tintedLayer(assets.image(name), size: CGSize(width: size, height: size), center: center, mask: &m)
    }

    private func text(_ t: CATextLayer, _ s: NSAttributedString, frame: CGRect, align: CATextLayerAlignmentMode = .left) {
        t.contentsScale = 2   // Retina; the canvas is ~1:1 with screen points
        t.alignmentMode = align
        t.isWrapped = true
        t.bounds = CGRect(origin: .zero, size: frame.size)
        t.position = CGPoint(x: frame.midX, y: frame.midY)
        t.transform = CATransform3DMakeScale(1, -1, 1)
        t.string = s
    }
    private func set(_ t: CATextLayer, _ s: NSAttributedString) {
        CATransaction.begin(); CATransaction.setDisableActions(true); t.string = s; CATransaction.commit()
    }

    /// Latin / digits: SF Mono. Kana and kanji fall back to Hiragino automatically.
    private func mono(_ s: String, _ size: CGFloat, _ color: NSColor = Boot.lime, weight: NSFont.Weight = .medium, kern: CGFloat = 1.5) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern])
    }
    /// Japanese UI text (Hiragino Sans). w: 3 / 6 / 8.
    private func jp(_ s: String, _ size: CGFloat, _ color: NSColor = Boot.lime, w: Int = 6, kern: CGFloat = 2) -> NSAttributedString {
        let f = NSFont(name: "HiraginoSans-W\(w)", size: size) ?? NSFont.systemFont(ofSize: size, weight: w >= 8 ? .heavy : (w >= 6 ? .semibold : .regular))
        return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .kern: kern])
    }
    private func mincho(_ s: String, _ size: CGFloat, _ color: NSColor, kern: CGFloat = 6) -> NSAttributedString {
        let f = NSFont(name: "HiraMinProN-W6", size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
        return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .kern: kern])
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }

    private func hexPath(center c: CGPoint, r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }

    /// Rectangle with chamfered top-left / bottom-right corners (corporate terminal panel).
    private func chamfer(_ r: CGRect, _ c: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c)); p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.closeSubpath()
        return p
    }

    private func brackets(_ r: CGRect, len: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + len * dx, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + len * dy))
        }
        return p
    }

    func fade(_ l: CALayer, to v: Float, _ d: Double, delay: Double = 0) {
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.fade(l, to: v, d) }; return }
        CATransaction.begin(); CATransaction.setAnimationDuration(d); l.opacity = v; CATransaction.commit()
    }

    private func flicker(_ l: CALayer) {
        let f = CAKeyframeAnimation(keyPath: "opacity"); f.values = [0, 1, 0.25, 1, 0.7, 1]; f.keyTimes = [0, 0.2, 0.3, 0.45, 0.55, 1]; f.duration = 0.5
        l.add(f, forKey: "flicker")
    }

    /// Plays a closing animation, then pins the final state (opacity 0) and removes the animation.
    private func close(_ l: CALayer, scaleKey: String, to s: CGFloat, duration: Double) {
        let g = CAAnimationGroup()
        let a = CABasicAnimation(keyPath: scaleKey); a.toValue = s
        let o = CABasicAnimation(keyPath: "opacity"); o.toValue = 0
        g.animations = [a, o]; g.duration = duration; g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards; g.isRemovedOnCompletion = false
        l.add(g, forKey: "close")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            CATransaction.begin(); CATransaction.setDisableActions(true); l.opacity = 0; l.removeAnimation(forKey: "close"); CATransaction.commit()
        }
    }

    /// Zoom-in "punch" for text layers. Animates the whole transform so the layer's y-flip is kept
    /// (a "transform.scale" animation would replace it and show the text upside down).
    private func punch(from k: CGFloat, duration: Double) -> CAAnimation {
        let flip = CATransform3DMakeScale(1, -1, 1)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: CATransform3DScale(flip, k, k, 1)); a.toValue = NSValue(caTransform3D: flip)
        a.duration = duration; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return a
    }

    private func repeating(_ interval: Double, _ block: @escaping (Timer) -> Void) {
        let t = Timer(timeInterval: interval, repeats: true, block: block)
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    // MARK: - Build

    private func build() {
        stage.bounds = CGRect(origin: .zero, size: Boot.canvas)
        stage.sublayerTransform = CATransform3DMakeScale(1, -1, 1)
        stage.masksToBounds = true
        stage.backgroundColor = Boot.ink.cgColor
        root.addSublayer(stage)
        buildBackground()
        buildHUD()
        buildSplash()
        buildLogin()
        buildRing()
        buildFinale()
        buildCards()
        flash.frame = stage.bounds
        flash.backgroundColor = Boot.lime.withAlphaComponent(0.6).cgColor
        flash.opacity = 0; flash.compositingFilter = "screenBlendMode"
        stage.addSublayer(flash)
        crt.bounds = CGRect(x: 0, y: 0, width: Boot.canvas.width, height: 2)
        crt.position = CGPoint(x: 800, y: 500)
        crt.backgroundColor = NSColor.white.cgColor
        crt.shadowColor = Boot.lime.cgColor; crt.shadowRadius = 12; crt.shadowOpacity = 1; crt.shadowOffset = .zero
        crt.opacity = 0
        stage.addSublayer(crt)
    }

    private func buildBackground() {
        var hm = CALayer()
        hexBG = tintedLayer(assets.image("fx_hex_mask"), size: CGSize(width: 1700, height: 1700), center: CGPoint(x: 800, y: 500), mask: &hm)
        hexBG.opacity = 0
        stage.addSublayer(hexBG)
        let grid = CAShapeLayer()
        let gp = CGMutablePath()
        for x in stride(from: CGFloat(0), through: Boot.canvas.width, by: 40) { gp.move(to: CGPoint(x: x, y: 0)); gp.addLine(to: CGPoint(x: x, y: Boot.canvas.height)) }
        for y in stride(from: CGFloat(0), through: Boot.canvas.height, by: 40) { gp.move(to: CGPoint(x: 0, y: y)); gp.addLine(to: CGPoint(x: Boot.canvas.width, y: y)) }
        grid.path = gp; grid.strokeColor = Boot.lime.withAlphaComponent(0.035).cgColor; grid.lineWidth = 1
        stage.addSublayer(grid)
        let vignette = CAGradientLayer()
        vignette.type = .radial; vignette.frame = stage.bounds
        vignette.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.9).cgColor]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5); vignette.endPoint = CGPoint(x: 1.1, y: 1.2)
        stage.addSublayer(vignette)
        let scan = CAReplicatorLayer(); scan.frame = stage.bounds
        let line = CALayer(); line.frame = CGRect(x: 0, y: 0, width: Boot.canvas.width, height: 1)
        line.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
        scan.addSublayer(line); scan.instanceCount = Int(Boot.canvas.height / 3); scan.instanceTransform = CATransform3DMakeTranslation(0, 3, 0)
        stage.addSublayer(scan)
        for (t, x) in [(rainL, CGFloat(18)), (rainR, Boot.canvas.width - 38)] {
            var s = ""
            for _ in 0..<160 { s += (0..<2).map { _ in Bool.random() ? "1" : "0" }.joined() + "\n" }
            text(t, mono(s, 10, Boot.lime.withAlphaComponent(0.3), kern: 2), frame: CGRect(x: x, y: -1800, width: 24, height: 3200))
            t.opacity = 0
            stage.addSublayer(t)
        }
    }

    private func buildHUD() {
        hud.frame = stage.bounds; hud.opacity = 0
        stage.addSublayer(hud)
        corners.path = brackets(stage.bounds.insetBy(dx: 26, dy: 26), len: 70)
        corners.strokeColor = Boot.lime.withAlphaComponent(0.85).cgColor; corners.fillColor = nil; corners.lineWidth = 2
        corners.strokeEnd = 0
        hud.addSublayer(corners)
        if let logo = assets.image(logoName) {
            let l = CALayer()
            let w: CGFloat = 140
            image(l, logo, frame: CGRect(x: 54, y: 46, width: w, height: w * CGFloat(logo.height) / CGFloat(logo.width)))
            hud.addSublayer(l)
        }
        let brand = CATextLayer()
        text(brand, jp("飛電インテリジェンス　社内ネットワーク", 13, Boot.lime.withAlphaComponent(0.85), w: 6, kern: 4),
             frame: CGRect(x: 214, y: 50, width: 760, height: 22))
        hud.addSublayer(brand)
        let sys = CATextLayer()
        text(sys, jp("機密端末　／　CODEX 作業環境", 13, Boot.lime.withAlphaComponent(0.85), w: 6, kern: 4),
             frame: CGRect(x: 1000, y: 50, width: 546, height: 22), align: .right)
        hud.addSublayer(sys)
        text(timecode, mono("T+00:00.00", 22, .white, weight: .semibold, kern: 3), frame: CGRect(x: 1146, y: 74, width: 400, height: 30), align: .right)
        hud.addSublayer(timecode)
        let rule = CAShapeLayer()
        let rp = CGMutablePath(); rp.move(to: CGPoint(x: 54, y: 112)); rp.addLine(to: CGPoint(x: 1546, y: 112))
        rp.move(to: CGPoint(x: 54, y: 800)); rp.addLine(to: CGPoint(x: 1546, y: 800))
        rule.path = rp; rule.strokeColor = Boot.lime.withAlphaComponent(0.22).cgColor; rule.lineWidth = 1; rule.lineDashPattern = [2, 6]
        hud.addSublayer(rule)

        // System module board: six hexagons per side (left: login chain, right: sync chain)
        let labels = [["通信", "衛星", "暗号", "認証", "生体", "承認"], ["同期", "演算", "CODEX", "展開", "防壁", "接続"]]
        for side in 0..<2 {
            for i in 0..<6 {
                let col = CGFloat(i % 2)
                let x = side == 0 ? 104 + col * 88 : Boot.canvas.width - 104 - col * 88
                let y = 200 + CGFloat(i) * 76
                let sh = CAShapeLayer()
                panelCenters.append(CGPoint(x: x, y: y))
                sh.path = hexPath(center: CGPoint(x: x, y: y), r: 50)
                sh.fillColor = Boot.lime.withAlphaComponent(0.03).cgColor
                sh.strokeColor = Boot.lime.withAlphaComponent(0.28).cgColor; sh.lineWidth = 1.5
                hud.addSublayer(sh)
                let t = CATextLayer()
                text(t, panelText(labels[side][i], .off), frame: CGRect(x: x - 48, y: y - 10, width: 96, height: 22), align: .center)
                hud.addSublayer(t)
                hexPanels.append((sh, t, labels[side][i], .off))
            }
        }
        text(log, mono("", 12, Boot.lime), frame: CGRect(x: 54, y: 812, width: 700, height: 150))
        hud.addSublayer(log)
        text(status, mono("", 12, Boot.lime), frame: CGRect(x: 946, y: 878, width: 600, height: 84), align: .right)
        hud.addSublayer(status)
    }

    private func panelText(_ s: String, _ st: PanelState) -> NSAttributedString {
        let c: NSColor = st == .on ? .black : (st == .blink ? .white : Boot.lime.withAlphaComponent(0.5))
        return s.unicodeScalars.allSatisfy({ $0.isASCII }) ? mono(s, 11, c, weight: .bold, kern: 1.5) : jp(s, 15, c, w: 6, kern: 3)
    }

    private func buildSplash() {
        splash.frame = stage.bounds; splash.opacity = 0
        stage.addSublayer(splash)
        let ls = crisp(logoName, maxW: 640)
        let top: CGFloat = 400 - ls.height / 2
        image(splashLogo, assets.image(logoName), frame: CGRect(x: 800 - ls.width / 2, y: top, width: ls.width, height: ls.height))
        splashLogo.shadowColor = Boot.lime.cgColor; splashLogo.shadowRadius = 26; splashLogo.shadowOpacity = 0.35; splashLogo.shadowOffset = .zero
        splash.addSublayer(splashLogo)
        text(splashJP, mincho("飛電インテリジェンス", 30, .white, kern: 14), frame: CGRect(x: 300, y: top + ls.height + 34, width: 1000, height: 44), align: .center)
        text(splashSub, jp("新時代の人工知能技術　・　社内システム起動中", 15, Boot.lime, w: 6, kern: 6),
             frame: CGRect(x: 300, y: top + ls.height + 86, width: 1000, height: 24), align: .center)
        [splashJP, splashSub].forEach(splash.addSublayer)
        splashBar.frame = CGRect(x: 600, y: top + ls.height + 132, width: 400, height: 3)
        splashBar.backgroundColor = Boot.lime.withAlphaComponent(0.18).cgColor
        splashBarFill.anchorPoint = .zero
        splashBarFill.bounds = CGRect(x: 0, y: 0, width: 400, height: 3); splashBarFill.position = .zero
        splashBarFill.backgroundColor = Boot.lime.cgColor
        splashBarFill.shadowColor = Boot.lime.cgColor; splashBarFill.shadowRadius = 6; splashBarFill.shadowOpacity = 1; splashBarFill.shadowOffset = .zero
        splashBar.addSublayer(splashBarFill)
        splash.addSublayer(splashBar)
    }

    private func buildLogin() {
        login.frame = stage.bounds; login.opacity = 0
        stage.addSublayer(login)
        let P = Boot.panel
        let glass = CAShapeLayer()
        glass.path = chamfer(P, 34)
        glass.fillColor = NSColor(red: 0.03, green: 0.05, blue: 0.035, alpha: 0.88).cgColor
        login.addSublayer(glass)
        loginFrame.path = chamfer(P, 34)
        loginFrame.fillColor = nil; loginFrame.strokeColor = Boot.lime.withAlphaComponent(0.7).cgColor; loginFrame.lineWidth = 1.5
        loginFrame.shadowColor = Boot.lime.cgColor; loginFrame.shadowRadius = 14; loginFrame.shadowOpacity = 0.35; loginFrame.shadowOffset = .zero
        login.addSublayer(loginFrame)
        loginBloom.path = chamfer(P, 34)
        loginBloom.bounds = stage.bounds; loginBloom.position = CGPoint(x: P.midX, y: P.midY)
        loginBloom.anchorPoint = CGPoint(x: P.midX / stage.bounds.width, y: P.midY / stage.bounds.height)
        loginBloom.fillColor = nil; loginBloom.strokeColor = Boot.lime.cgColor; loginBloom.lineWidth = 2
        loginBloom.shadowColor = Boot.lime.cgColor; loginBloom.shadowRadius = 18; loginBloom.shadowOpacity = 1; loginBloom.shadowOffset = .zero
        loginBloom.opacity = 0
        login.addSublayer(loginBloom)
        let header = CAShapeLayer()
        let hp = CGMutablePath()
        hp.move(to: CGPoint(x: P.minX + 34, y: P.minY)); hp.addLine(to: CGPoint(x: P.maxX, y: P.minY))
        hp.addLine(to: CGPoint(x: P.maxX, y: P.minY + 46)); hp.addLine(to: CGPoint(x: P.minX, y: P.minY + 46))
        hp.addLine(to: CGPoint(x: P.minX, y: P.minY + 34)); hp.closeSubpath()
        header.path = hp
        header.fillColor = Boot.lime.withAlphaComponent(0.92).cgColor
        login.addSublayer(header)
        let headL = CATextLayer(), headR = CATextLayer()
        text(headL, jp("社員認証システム", 18, .black, w: 8, kern: 6), frame: CGRect(x: P.minX + 50, y: P.minY + 11, width: 400, height: 26))
        text(headR, jp("機密区分　レベル01", 14, .black, w: 6, kern: 3), frame: CGRect(x: P.maxX - 300, y: P.minY + 14, width: 276, height: 22), align: .right)
        [headL, headR].forEach(login.addSublayer)
        let fields = ["社員番号", "氏　名", "役　職", "権　限", "端　末"]
        for (i, f) in fields.enumerated() {
            let y = P.minY + 76 + CGFloat(i) * 66
            let l = CATextLayer(), v = CATextLayer()
            text(l, jp(f, 13, Boot.lime.withAlphaComponent(0.7), w: 6, kern: 4), frame: CGRect(x: P.minX + 56, y: y, width: 300, height: 20))
            text(v, mono("", 22, .white), frame: CGRect(x: P.minX + 56, y: y + 22, width: 520, height: 34))
            let u = CAShapeLayer()
            let up = CGMutablePath(); up.move(to: CGPoint(x: P.minX + 56, y: y + 58)); up.addLine(to: CGPoint(x: P.minX + 540, y: y + 58))
            u.path = up; u.strokeColor = Boot.lime.withAlphaComponent(0.2).cgColor; u.lineWidth = 1
            [u, l, v].forEach(login.addSublayer)
            fieldValues.append(v)
        }
        text(authLine, jp("", 15, Boot.lime), frame: CGRect(x: P.minX + 56, y: P.maxY - 50, width: 520, height: 24))
        login.addSublayer(authLine)
        buildFingerprint()
    }

    /// Procedural fingerprint (original drawing): broken, slightly wavy concentric ridges clipped to a fingertip oval.
    private func buildFingerprint() {
        let S = Boot.scanFrame
        let bg = CAShapeLayer(); bg.path = CGPath(rect: S, transform: nil)
        bg.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        bg.strokeColor = Boot.lime.withAlphaComponent(0.25).cgColor; bg.lineWidth = 1
        login.addSublayer(bg)
        let grid = CAShapeLayer()
        let gp = CGMutablePath()
        for x in stride(from: S.minX, through: S.maxX, by: 20) { gp.move(to: CGPoint(x: x, y: S.minY)); gp.addLine(to: CGPoint(x: x, y: S.maxY)) }
        for y in stride(from: S.minY, through: S.maxY, by: 20) { gp.move(to: CGPoint(x: S.minX, y: y)); gp.addLine(to: CGPoint(x: S.maxX, y: y)) }
        grid.path = gp; grid.strokeColor = Boot.lime.withAlphaComponent(0.07).cgColor; grid.lineWidth = 1
        login.addSublayer(grid)

        let c = CGPoint(x: S.midX, y: S.midY - 8)
        var rng = Seeded(0x01_FEED)
        let ridges = CGMutablePath()
        for i in 0..<16 {
            let rx = 9 + CGFloat(i) * 7.4, ry = 12 + CGFloat(i) * 9.2
            if [4, 8, 12].contains(i) { fpRings.append(CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)) }
            let steps = 140
            var drawing = rng.next() > 0.2
            var nextToggle = rng.range(0.6, 2.4)
            var first = true
            for k in 0...steps {
                let th = CGFloat(k) / CGFloat(steps) * 2 * .pi
                let wob = 1 + 0.035 * sin(5 * th + CGFloat(i)) + 0.02 * sin(9 * th + CGFloat(i) * 0.7)
                let p = CGPoint(x: c.x + rx * wob * cos(th), y: c.y + ry * wob * sin(th) * (sin(th) > 0 ? 0.92 : 1))
                if th > nextToggle { drawing.toggle(); nextToggle = th + (drawing ? rng.range(0.7, 2.2) : rng.range(0.12, 0.32)); first = true }
                guard drawing else { continue }
                if first { ridges.move(to: p); first = false } else { ridges.addLine(to: p) }
            }
        }
        let tip = CAShapeLayer()
        tip.path = CGPath(ellipseIn: CGRect(x: c.x - 118, y: c.y - 148, width: 236, height: 296), transform: nil)
        let fp = CALayer(); fp.frame = stage.bounds; fp.mask = tip
        for (l, a, w) in [(fpBase, 0.16, 1.6), (fpLit, 1.0, 2.0)] as [(CAShapeLayer, CGFloat, CGFloat)] {
            l.path = ridges; l.fillColor = nil; l.lineCap = .round
            l.strokeColor = Boot.lime.withAlphaComponent(a).cgColor; l.lineWidth = w
            fp.addSublayer(l)
        }
        fpLit.shadowColor = Boot.lime.cgColor; fpLit.shadowRadius = 5; fpLit.shadowOpacity = 0.8; fpLit.shadowOffset = .zero
        fpBase.strokeEnd = 0
        for _ in 0..<3 {   // light points running along the ridges once the finger touches
            let d = CALayer(); d.bounds = CGRect(x: 0, y: 0, width: 5, height: 5); d.cornerRadius = 2.5
            d.backgroundColor = NSColor.white.cgColor
            d.shadowColor = Boot.lime.cgColor; d.shadowRadius = 6; d.shadowOpacity = 1; d.shadowOffset = .zero
            d.opacity = 0
            fp.addSublayer(d); fpRunners.append(d)
        }
        // Lit ridges are revealed top-down by the scan.
        fpMask.frame = stage.bounds
        fpMask.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        fpMask.locations = [0, 0, 0]
        let top = (S.minY) / Boot.canvas.height, bottom = S.maxY / Boot.canvas.height
        // Unit space starts at the bounds origin, which is the top of the canvas under the stage's y-down transform.
        fpMask.startPoint = CGPoint(x: 0.5, y: top); fpMask.endPoint = CGPoint(x: 0.5, y: bottom)
        fpLit.mask = fpMask
        login.addSublayer(fp)
        fpTip.path = CGPath(ellipseIn: CGRect(x: c.x - 118, y: c.y - 148, width: 236, height: 296), transform: nil)
        fpTip.fillColor = nil; fpTip.strokeColor = Boot.lime.withAlphaComponent(0.35).cgColor; fpTip.lineWidth = 1.2; fpTip.lineDashPattern = [3, 6]
        login.addSublayer(fpTip)
        fpNet.fillColor = nil; fpNet.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor; fpNet.lineWidth = 0.8
        login.addSublayer(fpNet)

        // Minutiae (feature points) found by the scan
        for _ in 0..<7 {
            let a = rng.range(0, 2 * .pi), r = rng.range(30, 110)
            let p = CGPoint(x: c.x + r * cos(a) * 0.8, y: c.y + r * sin(a))
            fpPoints.append(p)
            let d = CAShapeLayer()
            d.path = circle(p, 7); d.fillColor = nil; d.strokeColor = NSColor.white.cgColor; d.lineWidth = 1.5
            let tick = CGMutablePath(); tick.move(to: CGPoint(x: p.x + 7, y: p.y)); tick.addLine(to: CGPoint(x: p.x + 20, y: p.y - 9))
            let t = CAShapeLayer(); t.path = tick; t.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor; t.lineWidth = 1
            d.addSublayer(t)
            d.opacity = 0
            login.addSublayer(d)
            fpDots.append(d)
        }
        text(fpMatch, mono("", 13, Boot.lime, weight: .bold, kern: 2), frame: CGRect(x: S.minX + 12, y: S.maxY - 28, width: S.width - 24, height: 18), align: .right)
        login.addSublayer(fpMatch)

        let clip = CALayer(); clip.frame = S; clip.masksToBounds = true
        scanBeam.contents = assets.image("scan_glow"); scanBeam.contentsGravity = .resize
        scanBeam.bounds = CGRect(x: 0, y: 0, width: S.width + 120, height: 34)
        scanBeam.position = CGPoint(x: S.width / 2, y: 0)
        scanBeam.compositingFilter = "screenBlendMode"
        scanBeam.opacity = 0
        clip.addSublayer(scanBeam)
        login.addSublayer(clip)
        let br = CAShapeLayer(); br.path = brackets(S.insetBy(dx: -6, dy: -6), len: 26)
        br.strokeColor = Boot.lime.cgColor; br.fillColor = nil; br.lineWidth = 2
        login.addSublayer(br)
        text(scanLabel, jp("生体認証　待機中", 13, Boot.lime, w: 6, kern: 4), frame: CGRect(x: S.minX, y: S.maxY + 12, width: S.width, height: 20), align: .center)
        login.addSublayer(scanLabel)
    }

    private func buildRing() {
        ring.frame = stage.bounds; ring.opacity = 0
        stage.addSublayer(ring)
        let c = Boot.center, R = Boot.ringRadius
        let disc = CAShapeLayer(); disc.path = circle(c, R)
        disc.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor; disc.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor; disc.lineWidth = 2
        ring.addSublayer(disc)
        // ZEA: wireframe globe + tilted orbit with the satellite
        let globe = CAShapeLayer()
        let gp = CGMutablePath(); let gr: CGFloat = 78
        gp.addEllipse(in: CGRect(x: c.x - gr, y: c.y - gr, width: 2 * gr, height: 2 * gr))
        for k in [0.35, 0.7] as [CGFloat] { gp.addEllipse(in: CGRect(x: c.x - gr * k, y: c.y - gr, width: 2 * gr * k, height: 2 * gr)) }
        for k in [-0.5, 0, 0.5] as [CGFloat] {
            let y = c.y + gr * k, w = gr * sqrt(1 - k * k)
            gp.move(to: CGPoint(x: c.x - w, y: y)); gp.addLine(to: CGPoint(x: c.x + w, y: y))
        }
        globe.path = gp; globe.strokeColor = Boot.lime.withAlphaComponent(0.35).cgColor; globe.fillColor = nil; globe.lineWidth = 1
        ring.addSublayer(globe)
        let orbitRect = CGRect(x: -150, y: -46, width: 300, height: 92)
        orbit.bounds = orbitRect
        orbit.path = CGPath(ellipseIn: orbitRect, transform: nil)
        orbit.position = c
        orbit.strokeColor = Boot.lime.withAlphaComponent(0.6).cgColor; orbit.fillColor = nil; orbit.lineWidth = 1.2; orbit.lineDashPattern = [6, 5]
        orbit.transform = CATransform3DMakeRotation(-0.32, 0, 0, 1)
        ring.addSublayer(orbit)
        satellite.bounds = CGRect(x: 0, y: 0, width: 12, height: 12); satellite.cornerRadius = 6
        satellite.position = CGPoint(x: 150, y: 0)
        satellite.backgroundColor = Boot.lime.cgColor
        satellite.shadowColor = Boot.lime.cgColor; satellite.shadowRadius = 10; satellite.shadowOpacity = 1; satellite.shadowOffset = .zero
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = CGPath(ellipseIn: orbitRect, transform: nil)
        move.duration = 3.2; move.repeatCount = .infinity; move.calculationMode = .paced
        satellite.add(move, forKey: "orbit")
        orbit.addSublayer(satellite)
        syncBeam.strokeColor = Boot.lime.cgColor; syncBeam.lineWidth = 1.8; syncBeam.fillColor = nil; syncBeam.lineCap = .round
        syncBeam.opacity = 0
        ring.addSublayer(syncBeam)
        beamHit.bounds = CGRect(x: 0, y: 0, width: 8, height: 8); beamHit.cornerRadius = 4
        beamHit.backgroundColor = NSColor.white.cgColor
        beamHit.shadowColor = Boot.lime.cgColor; beamHit.shadowRadius = 8; beamHit.shadowOpacity = 1; beamHit.shadowOffset = .zero
        beamHit.opacity = 0
        ring.addSublayer(beamHit)
        for _ in 0..<16 {
            let d = CALayer(); d.bounds = CGRect(x: 0, y: 0, width: 4, height: 4); d.cornerRadius = 2
            d.backgroundColor = Boot.lime.cgColor
            d.shadowColor = Boot.lime.cgColor; d.shadowRadius = 5; d.shadowOpacity = 1; d.shadowOffset = .zero
            d.opacity = 0
            ring.addSublayer(d); flowDots.append(d)
        }
        let ticks = CAShapeLayer(); ticks.path = circle(.zero, R + 24); ticks.position = c
        ticks.strokeColor = Boot.lime.withAlphaComponent(0.5).cgColor; ticks.fillColor = nil; ticks.lineWidth = 6; ticks.lineDashPattern = [2, 10]
        let spin = CABasicAnimation(keyPath: "transform.rotation.z"); spin.byValue = Double.pi * 2; spin.duration = 18; spin.repeatCount = .infinity
        ticks.add(spin, forKey: "spin")
        ring.addSublayer(ticks)
        let arc = CGMutablePath(); arc.addArc(center: c, radius: R, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        ringArc.path = arc; ringArc.strokeColor = Boot.lime.cgColor; ringArc.fillColor = nil; ringArc.lineWidth = 7
        ringArc.strokeEnd = 0
        // Glow as two wide, faint strokes under the arc (a blurred shadow would be re-rendered every frame).
        for (w, a) in [(22.0, 0.10), (13.0, 0.20)] as [(CGFloat, CGFloat)] {
            let g = CAShapeLayer(); g.path = arc; g.fillColor = nil; g.lineWidth = w; g.lineCap = .butt
            g.strokeColor = Boot.lime.withAlphaComponent(a).cgColor; g.strokeEnd = 0
            ring.addSublayer(g); ringGlow.append(g)
        }
        ring.addSublayer(ringArc)
        let title = CATextLayer(), sub = CATextLayer()
        text(title, jp("人工知能衛星ゼア　同期中", 16, Boot.lime, w: 6, kern: 6), frame: CGRect(x: 500, y: c.y - R - 68, width: 600, height: 24), align: .center)
        text(ringValue, mono("0.0%", 60, .white, weight: .bold, kern: 1), frame: CGRect(x: 500, y: c.y + R + 30, width: 600, height: 72), align: .center)
        text(sub, jp("同期率　／　CODEX 作業環境との接続", 13, Boot.lime.withAlphaComponent(0.8), w: 6, kern: 4), frame: CGRect(x: 500, y: c.y + R + 98, width: 600, height: 20), align: .center)
        [title, ringValue, sub].forEach(ring.addSublayer)
    }

    private func buildFinale() {
        finale.frame = stage.bounds
        stage.addSublayer(finale)
        let c = Boot.logoCenter
        centerLight = tinted("fx_light_01", size: 1100, center: c)
        centerLight.opacity = 0; centerLight.compositingFilter = "screenBlendMode"
        finale.addSublayer(centerLight)

        var rng = Seeded(0x41D3)
        for _ in 0..<26 {   // streaks pointing at the centre
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: rng.range(60, 180), height: 2)
            l.backgroundColor = Boot.lime.cgColor
            l.opacity = 0
            finale.addSublayer(l); streaks.append(l)
        }
        for _ in 0..<44 {   // hex fragments
            let r = rng.range(5, 18)
            let h = CAShapeLayer()
            h.bounds = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
            h.path = hexPath(center: .zero, r: r)
            let solid = rng.next() > 0.5
            h.fillColor = solid ? Boot.lime.withAlphaComponent(0.8).cgColor : nil
            h.strokeColor = Boot.lime.cgColor; h.lineWidth = 1.5
            h.opacity = 0
            finale.addSublayer(h); fragments.append(h)
        }
        core.bounds = CGRect(x: 0, y: 0, width: 16, height: 16); core.cornerRadius = 8
        core.position = c
        core.backgroundColor = NSColor.white.cgColor
        core.shadowColor = Boot.lime.cgColor; core.shadowRadius = 22; core.shadowOpacity = 1; core.shadowOffset = .zero
        core.opacity = 0
        finale.addSublayer(core)
        for _ in 0..<3 {
            let s = CAShapeLayer()
            s.path = hexPath(center: .zero, r: 60); s.position = c
            s.fillColor = nil; s.strokeColor = Boot.lime.cgColor; s.lineWidth = 3
            s.opacity = 0
            finale.addSublayer(s); shocks.append(s)
        }
        emitter.emitterPosition = c; emitter.emitterShape = .rectangle; emitter.emitterSize = CGSize(width: 600, height: 120)
        emitter.renderMode = .additive; emitter.birthRate = 0
        emitter.emitterCells = [cell("fx_spark_01", 0.2, 30, 380, 0.9), cell("fx_star_01", 0.08, 90, 260, 1.4)]
        finale.addSublayer(emitter)

        // The logo, cut into horizontal strips for the glitch assembly.
        let ls = crisp(logoName, maxW: 720)
        let frame = CGRect(x: c.x - ls.width / 2, y: c.y - ls.height / 2, width: ls.width, height: ls.height)
        logoGroup.frame = frame
        finale.addSublayer(logoGroup)
        let box = CGRect(origin: .zero, size: ls)
        // Chromatic copies (magenta / cyan) for the RGB split while the logo forms.
        var cm = CALayer()
        chromaA = tintedLayer(assets.image(logoName), size: ls, center: CGPoint(x: box.midX, y: box.midY), color: NSColor(red: 1, green: 0.15, blue: 0.55, alpha: 1), mask: &cm)
        chromaB = tintedLayer(assets.image(logoName), size: ls, center: CGPoint(x: box.midX, y: box.midY), color: NSColor(red: 0.1, green: 0.9, blue: 1, alpha: 1), mask: &cm)
        for l in [chromaA, chromaB] { l.opacity = 0; l.compositingFilter = "screenBlendMode"; logoGroup.addSublayer(l) }
        logoHost.frame = box
        logoHost.shadowColor = Boot.lime.cgColor; logoHost.shadowRadius = 28; logoHost.shadowOpacity = 0.55; logoHost.shadowOffset = .zero
        logoHost.opacity = 0
        let n = 9
        for i in 0..<n {
            let strip = CALayer()
            strip.anchorPoint = .zero
            let h = ls.height / CGFloat(n)
            strip.bounds = CGRect(x: 0, y: 0, width: ls.width, height: h + 0.5)
            strip.position = CGPoint(x: 0, y: CGFloat(i) * h)
            strip.masksToBounds = true
            let img = CALayer()
            image(img, assets.image(logoName), frame: CGRect(x: 0, y: -CGFloat(i) * h, width: ls.width, height: ls.height))
            strip.addSublayer(img)
            logoHost.addSublayer(strip); logoSlices.append(strip)
        }
        logoGroup.addSublayer(logoHost)
        // Light sweep, clipped to the logo's shape.
        sweepHost.frame = box
        let m = CALayer(); image(m, assets.image(logoName), frame: CGRect(origin: .zero, size: ls))
        sweepHost.mask = m
        sweepBand.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.95).cgColor,
                            Boot.lime.withAlphaComponent(0.9).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        sweepBand.locations = [0, 0.45, 0.6, 1]
        sweepBand.startPoint = CGPoint(x: 0, y: 0.5); sweepBand.endPoint = CGPoint(x: 1, y: 0.5)
        sweepBand.bounds = CGRect(x: 0, y: 0, width: 220, height: ls.height * 1.6)
        sweepBand.position = CGPoint(x: -240, y: ls.height / 2)
        sweepBand.transform = CATransform3DMakeRotation(0.28, 0, 0, 1)
        sweepHost.addSublayer(sweepBand)
        sweepHost.opacity = 0
        logoGroup.addSublayer(sweepHost)
        // Faint holographic scanlines on the logo surface.
        holoHost.frame = box
        let hm = CALayer(); image(hm, assets.image(logoName), frame: box)
        holoHost.mask = hm
        holo.frame = CGRect(x: 0, y: -8, width: ls.width, height: ls.height + 16)
        let line = CALayer(); line.frame = CGRect(x: 0, y: 0, width: ls.width, height: 1.2)
        line.backgroundColor = Boot.lime.cgColor
        holo.addSublayer(line); holo.instanceCount = Int(ls.height / 4) + 6; holo.instanceTransform = CATransform3DMakeTranslation(0, 4, 0)
        holoHost.addSublayer(holo)
        holoHost.opacity = 0
        logoGroup.addSublayer(holoHost)

        let y0 = frame.maxY + 30
        text(logoJP, mincho("飛電インテリジェンス", 32, .white, kern: 18), frame: CGRect(x: 300, y: y0, width: 1000, height: 46), align: .center)
        let rp = CGMutablePath()
        rp.move(to: CGPoint(x: 470, y: y0 + 74)); rp.addLine(to: CGPoint(x: 1130, y: y0 + 74))
        rp.move(to: CGPoint(x: 470, y: y0 + 172)); rp.addLine(to: CGPoint(x: 1130, y: y0 + 172))
        logoRules.path = rp; logoRules.strokeColor = Boot.lime.withAlphaComponent(0.8).cgColor; logoRules.lineWidth = 2
        logoRules.strokeEnd = 0
        text(grantJP, jp("アクセス承認", 64, Boot.lime, w: 8, kern: 18), frame: CGRect(x: 300, y: y0 + 84, width: 1000, height: 84), align: .center)
        grantJP.shadowColor = Boot.lime.cgColor; grantJP.shadowRadius = 16; grantJP.shadowOpacity = 0.6; grantJP.shadowOffset = .zero
        text(welcome, mincho("お帰りなさいませ、社長", 28, .white, kern: 10), frame: CGRect(x: 300, y: y0 + 190, width: 1000, height: 42), align: .center)
        text(logoEN, mono("HIDEN INTELLIGENCE  ·  ACCESS GRANTED  ·  CODEX", 11, Boot.lime.withAlphaComponent(0.65), weight: .semibold, kern: 5),
             frame: CGRect(x: 300, y: y0 + 246, width: 1000, height: 16), align: .center)
        for l in [logoJP, grantJP, welcome, logoEN] as [CALayer] { l.opacity = 0; finale.addSublayer(l) }
        let sr = CGRect(x: 0, y: 0, width: 580, height: 98)
        stampRing.bounds = sr; stampRing.position = CGPoint(x: 800, y: y0 + 126)
        stampRing.path = CGPath(roundedRect: sr, cornerWidth: 10, cornerHeight: 10, transform: nil)
        stampRing.fillColor = nil; stampRing.strokeColor = Boot.lime.cgColor; stampRing.lineWidth = 2
        stampRing.shadowColor = Boot.lime.cgColor; stampRing.shadowRadius = 12; stampRing.shadowOpacity = 1; stampRing.shadowOffset = .zero
        stampRing.opacity = 0
        finale.addSublayer(stampRing)
        finale.addSublayer(logoRules)
    }

    private func cell(_ name: String, _ scale: CGFloat, _ rate: Float, _ v: CGFloat, _ life: Float) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = assets.image(name); c.color = Boot.lime.cgColor
        c.birthRate = rate; c.lifetime = life; c.lifetimeRange = life * 0.35
        c.velocity = v; c.velocityRange = v * 0.4; c.emissionRange = .pi * 2
        c.scale = scale; c.scaleRange = scale * 0.5; c.scaleSpeed = -scale * 0.4
        c.alphaSpeed = -1 / life; c.spin = 1.5; c.spinRange = 5
        return c
    }

    private func buildCards() {
        cards.frame = stage.bounds; cards.opacity = 0
        stage.addSublayer(cards)
        // Card wipe: a soft-edged band sweeping left to right, drawn by the GPU from a gradient mask
        // (a bitmap frame sequence had to be handed to the render server and stalled the main thread ~180 ms).
        wipe.frame = stage.bounds.insetBy(dx: -40, dy: -40)
        // The mask is a fixed gradient (solid, then a soft right edge 8 % of the width) that slides in from the left.
        let W = wipe.bounds.width, edge = W * 0.08
        wipeMask.anchorPoint = .zero
        wipeMask.bounds = CGRect(x: 0, y: 0, width: W + edge, height: wipe.bounds.height)
        wipeMask.position = .zero                       // final state: fully covered
        wipeMask.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        wipeMask.locations = [0, NSNumber(value: Double(W / (W + edge))), 1]
        wipeMask.startPoint = CGPoint(x: 0, y: 0.5); wipeMask.endPoint = CGPoint(x: 1, y: 0.5)
        wipe.mask = wipeMask
        cards.addSublayer(wipe)
        let rp = CGMutablePath()
        rp.move(to: CGPoint(x: 160, y: 340)); rp.addLine(to: CGPoint(x: 1440, y: 340))
        rp.move(to: CGPoint(x: 160, y: 660)); rp.addLine(to: CGPoint(x: 1440, y: 660))
        cardRules.path = rp; cardRules.lineWidth = 3
        cards.addSublayer(cardRules)
        [cardTag, cardTitle, cardSub].forEach(cards.addSublayer)
    }

    // MARK: - Frame clock

    func onFrame(_ key: String, _ f: ((CFTimeInterval) -> Void)?) { frameHandlers[key] = f }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        let l = displayLink(target: self, selector: #selector(frameTick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: Self.fps, maximum: Self.fps, preferred: Self.fps)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func frameTick(_ l: CADisplayLink) {
        if perfLast > 0 {
            if perfFrames[perfPhase] == nil { perfOrder.append(perfPhase) }
            perfFrames[perfPhase, default: []].append(l.timestamp - perfLast)
        }
        perfLast = l.timestamp
        let now = CACurrentMediaTime()
        for f in Array(frameHandlers.values) { f(now) }
    }

    /// "phase: frames, mean ms, p95 ms, worst ms, dropped" for every phase seen so far.
    func perfReport() -> [String] {
        let budget = 1.0 / Double(Self.fps)
        return perfOrder.compactMap { name in
            guard let d = perfFrames[name], !d.isEmpty else { return nil }
            let sorted = d.sorted(), mean = d.reduce(0, +) / Double(d.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let dropped = d.reduce(0) { $0 + max(0, Int(($1 / budget).rounded()) - 1) }
            return String(format: "%@: %d frames, mean %.1f ms, p95 %.1f ms, worst %.1f ms, dropped %d", name, d.count, mean * 1000, p95 * 1000, (sorted.last ?? 0) * 1000, dropped)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let s = min(bounds.width / Boot.canvas.width, bounds.height / Boot.canvas.height)
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        stage.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }

    func viewPoint(stage p: CGPoint) -> CGPoint {
        let s = min(bounds.width / Boot.canvas.width, bounds.height / Boot.canvas.height)
        return CGPoint(x: (p.x - Boot.canvas.width / 2) * s + bounds.midX, y: bounds.midY - (p.y - Boot.canvas.height / 2) * s)
    }

    // MARK: - Clock, log, status, panels

    func startClock() {
        started = CACurrentMediaTime()
        var shown = ""
        onFrame("clock") { [weak self] now in
            guard let self else { return }
            let t = now - self.started
            let str = String(format: "T+%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
            if str != shown { shown = str; self.set(self.timecode, self.mono(str, 22, .white, weight: .semibold, kern: 3)) }
        }
    }
    func stopClock() { onFrame("clock", nil) }

    func addLog(_ line: String, highlight: Bool = false) {
        logLines.append(line)
        if logLines.count > 7 { logLines.removeFirst() }
        let s = NSMutableAttributedString()
        for (i, l) in logLines.enumerated() {
            let last = i == logLines.count - 1
            s.append(mono("▸ " + l + "\n", 12.5, last && highlight ? .white : Boot.lime.withAlphaComponent(last ? 1 : 0.5), weight: last ? .semibold : .medium))
        }
        set(log, s)
    }

    func setStatus(_ state: String) {
        let s = NSMutableAttributedString()
        s.append(jp("利用者　飛電 或人　／　接続先　CODEX\n", 12.5, Boot.lime.withAlphaComponent(0.8), w: 3, kern: 2))
        s.append(jp("状態　" + state, 15, .white, w: 6, kern: 3))
        set(status, s)
    }

    func setPanel(_ i: Int, _ st: PanelState) {
        guard i < hexPanels.count, hexPanels[i].state != st else { return }
        hexPanels[i].state = st
        let p = hexPanels[i]
        p.shape.removeAnimation(forKey: "blink")
        CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
        switch st {
        case .off: p.shape.fillColor = Boot.lime.withAlphaComponent(0.03).cgColor; p.shape.strokeColor = Boot.lime.withAlphaComponent(0.28).cgColor
        case .blink:
            p.shape.fillColor = Boot.red.withAlphaComponent(0.25).cgColor; p.shape.strokeColor = Boot.red.cgColor
            let b = CABasicAnimation(keyPath: "opacity"); b.fromValue = 1; b.toValue = 0.25; b.duration = 0.18; b.autoreverses = true; b.repeatCount = .infinity
            p.shape.add(b, forKey: "blink")
        case .on: p.shape.fillColor = Boot.lime.withAlphaComponent(0.85).cgColor; p.shape.strokeColor = Boot.lime.cgColor
        }
        CATransaction.commit()
        set(p.label, panelText(p.text, st))
    }
    var panelCount: Int { hexPanels.count }

    // MARK: - Boot / splash

    func powerOn() {
        crt.opacity = 1
        let w = CABasicAnimation(keyPath: "bounds.size.width"); w.fromValue = 0; w.toValue = Boot.canvas.width; w.duration = 0.28
        w.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let h = CAKeyframeAnimation(keyPath: "bounds.size.height"); h.values = [2, 2, 600, 0]; h.keyTimes = [0, 0.45, 0.7, 1]; h.duration = 0.62
        let o = CAKeyframeAnimation(keyPath: "opacity"); o.values = [1, 1, 0.35, 0]; o.keyTimes = [0, 0.6, 0.85, 1]; o.duration = 0.62
        let g = CAAnimationGroup(); g.animations = [w, h, o]; g.duration = 0.62
        crt.add(g, forKey: "on")
        crt.opacity = 0
        fade(hud, to: 1, 0.4, delay: 0.35)
        fade(hexBG, to: 0.06, 1.2, delay: 0.4)
        fade(rainL, to: 1, 1, delay: 0.6); fade(rainR, to: 1, 1, delay: 0.6)
        for (t, dir) in [(rainL, 1.0), (rainR, -1.0)] {
            let a = CABasicAnimation(keyPath: "position.y"); a.byValue = 1200 * dir; a.duration = 40; a.repeatCount = .infinity
            t.add(a, forKey: "rain")
        }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.9)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        corners.strokeEnd = 1
        CATransaction.commit()
    }

    /// Corporate splash: Hiden Intelligence logo with a loading bar that fills over `duration`.
    func showSplash(duration: Double) {
        splash.opacity = 1
        flicker(splashLogo)
        let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 1.05; s.toValue = 1; s.duration = 1.6
        s.timingFunction = CAMediaTimingFunction(name: .easeOut)
        splash.add(s, forKey: "in")
        for (i, l) in [splashJP, splashSub, splashBar].enumerated() { l.opacity = 0; fade(l, to: 1, 0.4, delay: 0.3 + Double(i) * 0.18) }
        let b = CABasicAnimation(keyPath: "bounds.size.width"); b.fromValue = 0; b.toValue = 400; b.duration = duration
        b.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        splashBarFill.add(b, forKey: "load")
    }
    func hideSplash() { close(splash, scaleKey: "transform.scale", to: 0.92, duration: 0.35) }

    // MARK: - Login

    func openLogin() {
        login.opacity = 1
        let s = CABasicAnimation(keyPath: "transform.scale.y"); s.fromValue = 0.02; s.toValue = 1; s.duration = 0.32
        s.timingFunction = CAMediaTimingFunction(name: .easeOut)
        login.add(s, forKey: "open")
        flicker(loginFrame)
    }

    /// Types a field value; `onChar` fires every few characters (tick sound).
    func typeField(_ i: Int, _ value: String, cps: Double = 30, onChar: (() -> Void)? = nil) {
        guard i < fieldValues.count else { return }
        let chars = Array(value)
        var n = 0
        repeating(1 / cps) { [weak self] t in
            guard let self else { t.invalidate(); return }
            n += 1
            let shown = String(chars.prefix(n)) + (n < chars.count ? "▌" : "")
            self.set(self.fieldValues[i], self.jp(shown, 21, .white, w: 6, kern: 2))
            if n % 2 == 1 { onChar?() }
            if n >= chars.count { t.invalidate() }
        }
    }

    func setAuthLine(_ s: String, color: NSColor = Boot.lime) { set(authLine, jp(s, 15, color, w: 6, kern: 4)) }
    func setScanLabel(_ s: String) { set(scanLabel, jp(s, 13, Boot.lime, w: 6, kern: 4)) }

    /// The finger touches: ridges draw themselves in, the tip outline pulses, light points start running along ridges.
    func fingerprintContact(duration: Double = 0.5) {
        CATransaction.begin(); CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fpBase.strokeEnd = 1
        CATransaction.commit()
        let pulse = CAKeyframeAnimation(keyPath: "opacity"); pulse.values = [1, 0.25, 1]; pulse.duration = 0.45
        fpTip.add(pulse, forKey: "touch")
        for (i, d) in fpRunners.enumerated() where i < fpRings.count {
            d.opacity = 0.9
            let a = CAKeyframeAnimation(keyPath: "position"); a.path = fpRings[i]; a.calculationMode = .paced
            a.duration = 1.4 + Double(i) * 0.5; a.repeatCount = .infinity; a.timeOffset = Double(i) * 0.6
            d.add(a, forKey: "run")
        }
        setScanLabel("指を検出　照合準備")
    }

    /// Fingerprint scan: ridges light up top-down behind the beam, feature points lock on one by one and are joined
    /// into a feature graph, match rate counts up. `onLock` fires for each of the first few locks (sound).
    func fingerprintScan(duration: Double, onLock: ((Int) -> Void)? = nil) {
        let a = CABasicAnimation(keyPath: "locations"); a.fromValue = [0, 0, 0]; a.toValue = [0, 1, 1]; a.duration = duration * 0.75
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fpMask.locations = [0, 1, 1]
        fpMask.add(a, forKey: "scan")
        scanBeam.opacity = 1
        let b = CABasicAnimation(keyPath: "position.y"); b.fromValue = -10; b.toValue = Boot.scanFrame.height + 10
        b.duration = duration * 0.75; b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scanBeam.add(b, forKey: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.75) { [weak self] in
            guard let self else { return }
            self.fade(self.scanBeam, to: 0, 0.2)
        }
        for (i, d) in fpDots.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * (0.18 + 0.11 * Double(i))) { [weak self] in
                guard let self else { return }
                d.opacity = 1
                let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 2.2; s.toValue = 1; s.duration = 0.2
                d.add(s, forKey: "lock")
                if i > 0, i < self.fpPoints.count {
                    let p = CGMutablePath(); p.move(to: self.fpPoints[0])
                    for k in 1...i { p.addLine(to: self.fpPoints[k]) }
                    CATransaction.begin(); CATransaction.setDisableActions(true); self.fpNet.path = p; CATransaction.commit()
                }
                if i < 5 { onLock?(i) }
            }
        }
        let t0 = CACurrentMediaTime()
        onFrame("fpCount") { [weak self] now in
            guard let self else { return }
            let x = min(1, (now - t0) / duration)
            let v = 99.8 * (1 - pow(1 - x, 2))
            self.set(self.fpMatch, self.mono(String(format: "照合率  %.1f%%", v), 13, x >= 1 ? .white : Boot.lime, weight: .bold, kern: 2))
            if x >= 1 { self.onFrame("fpCount", nil) }
        }
    }

    func authorizedFlash() {
        let a = CAKeyframeAnimation(keyPath: "strokeColor")
        a.values = [Boot.lime.cgColor, NSColor.white.cgColor, Boot.lime.cgColor, NSColor.white.cgColor, Boot.lime.cgColor]; a.duration = 0.5
        loginFrame.add(a, forKey: "auth")
        let g = CAKeyframeAnimation(keyPath: "shadowOpacity"); g.values = [0.35, 1, 0.35]; g.duration = 0.6
        loginFrame.add(g, forKey: "glow")
        fpLit.strokeColor = NSColor.white.cgColor
        // Border bloom spreading outward from the panel.
        let g2 = CAAnimationGroup()
        let sc = CABasicAnimation(keyPath: "transform.scale"); sc.fromValue = 1; sc.toValue = 1.035
        let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0.9; op.toValue = 0
        let lw = CABasicAnimation(keyPath: "lineWidth"); lw.fromValue = 5; lw.toValue = 0.5
        g2.animations = [sc, op, lw]; g2.duration = 0.75; g2.timingFunction = CAMediaTimingFunction(name: .easeOut)
        loginBloom.add(g2, forKey: "bloom")
        for d in fpRunners { fade(d, to: 0, 0.3) }
        fpTip.strokeColor = Boot.lime.cgColor
    }

    func closeLogin() {
        timers.forEach { $0.invalidate() }; timers.removeAll()
        close(login, scaleKey: "transform.scale.y", to: 0.02, duration: 0.3)
    }

    // MARK: - Sync ring

    func showRing(_ on: Bool) {
        if on {
            ring.removeAnimation(forKey: "close")
            fade(ring, to: 1, 0.4)
            syncPhase = CACurrentMediaTime()
            startFlow()
            let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 0.6; s.toValue = 1; s.duration = 0.5
            s.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(s, forKey: "in")
        } else {
            stopFlow()
            close(ring, scaleKey: "transform.scale", to: 0.02, duration: 0.45)
        }
    }

    func setSync(_ v: Double) {
        let x = max(0, min(100, v))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ringArc.strokeEnd = CGFloat(x / 100)
        for g in ringGlow { g.strokeEnd = CGFloat(x / 100) }
        ringValue.string = mono(String(format: "%.1f%%", x), 60, x >= 100 ? Boot.lime : .white, weight: .bold, kern: 1)
        CATransaction.commit()
    }

    // Satellite beam: the ZEA satellite briefly links down to the globe every 1.7 s (called at 30 fps while syncing).
    private var syncPhase = CACurrentMediaTime()
    func syncFX() {
        guard ring.opacity > 0.01, let sp = satellite.presentation()?.position else { return }
        let s = ring.convert(sp, from: orbit)
        let c = Boot.center
        let dx = s.x - c.x, dy = s.y - c.y, len = max(1, hypot(dx, dy))
        let hit = CGPoint(x: c.x + dx / len * 78, y: c.y + dy / len * 78)
        let ph = (CACurrentMediaTime() - syncPhase).truncatingRemainder(dividingBy: 1.7) / 1.7
        let a = Float(ph < 0.32 ? sin(ph / 0.32 * .pi) : 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let p = CGMutablePath(); p.move(to: s); p.addLine(to: hit)
        syncBeam.path = p; syncBeam.opacity = a * 0.8
        beamHit.position = hit; beamHit.opacity = a
        CATransaction.commit()
    }

    // Data flow: small points of light travel from the lit system modules into the sync ring.
    private var flowRng = Seeded(0xF10)
    private func startFlow() {
        flowTimer?.invalidate()
        flowTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.spawnFlow() }
    }
    private func stopFlow() { flowTimer?.invalidate(); flowTimer = nil }
    private func spawnFlow() {
        guard !panelCenters.isEmpty, !flowDots.isEmpty else { return }
        let lit = hexPanels.indices.filter { hexPanels[$0].state != .off }
        let pool = lit.isEmpty ? Array(hexPanels.indices) : lit
        let i = pool[min(pool.count - 1, Int(flowRng.next() * CGFloat(pool.count)))]
        let from = panelCenters[i], c = Boot.center
        let dx = from.x - c.x, dy = from.y - c.y, len = max(1, hypot(dx, dy))
        let to = CGPoint(x: c.x + dx / len * (Boot.ringRadius + 8), y: c.y + dy / len * (Boot.ringRadius + 8))
        let ctrl = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + flowRng.range(-70, 70))
        let path = CGMutablePath(); path.move(to: from); path.addQuadCurve(to: to, control: ctrl)
        let d = flowDots[flowIndex % flowDots.count]; flowIndex += 1
        let mv = CAKeyframeAnimation(keyPath: "position"); mv.path = path
        let op = CAKeyframeAnimation(keyPath: "opacity"); op.values = [0, 1, 1, 0]; op.keyTimes = [0, 0.15, 0.8, 1]
        let g = CAAnimationGroup(); g.animations = [mv, op]; g.duration = 0.95; g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin(); CATransaction.setDisableActions(true); d.position = to; d.opacity = 0; CATransaction.commit()
        d.add(g, forKey: "flow")
    }

    func ringFlash() {
        let a = CAKeyframeAnimation(keyPath: "lineWidth"); a.values = [7, 22, 7]; a.duration = 0.5
        ringArc.add(a, forKey: "flash")
    }

    // MARK: - Cards (EVA-style full-screen type)

    private var preparedCard: String?
    private func layoutCard(_ title: String, _ sub: String, _ tag: String, _ style: CardStyle) {
        let fg: NSColor = style == .black ? Boot.lime : .black
        CATransaction.begin(); CATransaction.setDisableActions(true)
        text(cardTitle, jp(title, 200, fg, w: 8, kern: 60), frame: CGRect(x: 40, y: 360, width: 1520, height: 240), align: .center)
        text(cardSub, mono(sub, 26, fg, weight: .heavy, kern: 22), frame: CGRect(x: 60, y: 606, width: 1480, height: 36), align: .center)
        text(cardTag, jp(tag, 16, fg, w: 6, kern: 8), frame: CGRect(x: 60, y: 306, width: 1480, height: 24), align: .center)
        cardRules.strokeColor = fg.cgColor
        wipe.backgroundColor = (style == .black ? NSColor.black : Boot.lime).cgColor
        CATransaction.commit()
    }
    /// Lays out and renders a card's text ahead of time (at a quiet moment), so showing it later costs nothing.
    func prepareCard(_ title: String, sub: String, tag: String, style: CardStyle) {
        layoutCard(title, sub, tag, style)
        for l in [cardTitle, cardSub, cardTag] { l.display() }
        preparedCard = "\(title)|\(sub)|\(tag)|\(style)"
    }

    func card(_ title: String, sub: String, tag: String, style: CardStyle, hold: Double) {
        if preparedCard != "\(title)|\(sub)|\(tag)|\(style)" { layoutCard(title, sub, tag, style) }
        preparedCard = nil
        let w = CABasicAnimation(keyPath: "position.x")
        w.fromValue = -wipeMask.bounds.width; w.toValue = 0; w.duration = 0.4
        w.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        wipeMask.add(w, forKey: "wipe")
        let total = hold + 0.5
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, 1, 1, 0]; o.keyTimes = [0, NSNumber(value: 0.06 / total), NSNumber(value: (hold + 0.35) / total), 1]; o.duration = total
        cards.add(o, forKey: "show")
        cards.opacity = 1
        cardToken += 1
        let tok = cardToken
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
            guard let self, self.cardToken == tok else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true); self.cards.opacity = 0; CATransaction.commit()
        }
        for l in [cardTitle, cardSub, cardTag] { l.add(punch(from: 1.18, duration: 0.35), forKey: "punch") }
        let f = CAKeyframeAnimation(keyPath: "opacity"); f.values = [0, 1, 0.2, 1]; f.keyTimes = [0, 0.3, 0.5, 1]; f.duration = 0.25
        cardTitle.add(f, forKey: "flicker")
    }

    // MARK: - Hiden logo finale

    /// Light point + hex fragments + streaks fly into the centre.
    func logoConverge(duration: Double) {
        let c = Boot.logoCenter
        core.opacity = 1
        let g = CAKeyframeAnimation(keyPath: "transform.scale"); g.values = [0.3, 1, 2.6]; g.keyTimes = [0, 0.3, 1]; g.duration = duration
        core.add(g, forKey: "grow")
        fade(centerLight, to: 0.25, duration)
        var rng = Seeded(0xC0DE)
        let now = CACurrentMediaTime()
        for f in fragments {
            let a = rng.range(0, 2 * .pi), r = rng.range(480, 950), delay = Double(rng.range(0, 0.45))
            let start = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a) * 0.75)
            let mv = CABasicAnimation(keyPath: "position"); mv.fromValue = NSValue(point: start); mv.toValue = NSValue(point: c)
            let sc = CABasicAnimation(keyPath: "transform.scale"); sc.fromValue = 1.4; sc.toValue = 0.2
            let rot = CABasicAnimation(keyPath: "transform.rotation.z"); rot.byValue = Double(rng.range(-3, 3))
            let op = CAKeyframeAnimation(keyPath: "opacity"); op.values = [0, 1, 1, 0]; op.keyTimes = [0, 0.15, 0.85, 1]
            let grp = CAAnimationGroup(); grp.animations = [mv, sc, rot, op]
            grp.duration = duration - delay; grp.beginTime = now + delay; grp.fillMode = .backwards
            grp.timingFunction = CAMediaTimingFunction(name: .easeIn)
            f.position = c
            f.add(grp, forKey: "in")
        }
        for s in streaks {
            let a = rng.range(0, 2 * .pi), r = rng.range(520, 900), delay = Double(rng.range(0, 0.5))
            s.setAffineTransform(CGAffineTransform(rotationAngle: a))
            let start = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            let end = CGPoint(x: c.x + 40 * cos(a), y: c.y + 40 * sin(a))
            let mv = CABasicAnimation(keyPath: "position"); mv.fromValue = NSValue(point: start); mv.toValue = NSValue(point: end)
            let op = CAKeyframeAnimation(keyPath: "opacity"); op.values = [0, 0.9, 0]; op.keyTimes = [0, 0.5, 1]
            let grp = CAAnimationGroup(); grp.animations = [mv, op]
            grp.duration = (duration - delay) * 0.8; grp.beginTime = now + delay; grp.fillMode = .backwards
            grp.timingFunction = CAMediaTimingFunction(name: .easeIn)
            s.position = end
            s.add(grp, forKey: "in")
        }
    }

    /// Flash, hex shockwaves, the logo assembles from shifted glitch strips.
    func logoForm() {
        core.removeAllAnimations(); core.opacity = 0
        let f = CAKeyframeAnimation(keyPath: "opacity"); f.values = [0, 0.8, 0]; f.keyTimes = [0, 0.1, 1]; f.duration = 0.6
        flash.add(f, forKey: "flash")
        let now = CACurrentMediaTime()
        for (i, s) in shocks.enumerated() {
            let g = CAAnimationGroup()
            let sc = CABasicAnimation(keyPath: "transform.scale"); sc.fromValue = 0.3; sc.toValue = 9 + Double(i) * 3
            let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0.9; op.toValue = 0
            let lw = CABasicAnimation(keyPath: "lineWidth"); lw.fromValue = 6; lw.toValue = 0.5
            g.animations = [sc, op, lw]; g.duration = 1.1; g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.beginTime = now + Double(i) * 0.14; g.fillMode = .backwards
            s.add(g, forKey: "wave")
        }
        let hp = CAKeyframeAnimation(keyPath: "opacity"); hp.values = [0.06, 0.45, 0.14]; hp.keyTimes = [0, 0.12, 1]; hp.duration = 1.6
        hexBG.add(hp, forKey: "pulse"); hexBG.opacity = 0.14
        fade(centerLight, to: 0.32, 0.4)
        emitter.beginTime = CACurrentMediaTime(); emitter.birthRate = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.emitter.birthRate = 0 }

        logoHost.opacity = 1
        var rng = Seeded(0x5EED)
        for strip in logoSlices {
            let dx = rng.range(-140, 140)
            let x = CAKeyframeAnimation(keyPath: "position.x")
            x.values = [dx, -dx * 0.4, dx * 0.15, 0]; x.keyTimes = [0, 0.4, 0.7, 1]
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = [0, 1, 0.3, 1, 0.6, 1]; o.keyTimes = [0, 0.15, 0.3, 0.5, 0.7, 1]
            let g = CAAnimationGroup(); g.animations = [x, o]; g.duration = Double(rng.range(0.4, 0.65))
            g.beginTime = now + Double(rng.range(0, 0.12)); g.fillMode = .backwards
            strip.add(g, forKey: "glitch")
        }
        let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 1.12; s.toValue = 1; s.duration = 0.5
        s.timingFunction = CAMediaTimingFunction(name: .easeOut)
        logoHost.add(s, forKey: "settle")
        let glow = CAKeyframeAnimation(keyPath: "shadowRadius"); glow.values = [70, 28]; glow.duration = 0.9
        logoHost.add(glow, forKey: "glow")
        // RGB split that settles into the logo.
        for (l, dx) in [(chromaA, -12.0), (chromaB, 12.0)] as [(CALayer, CGFloat)] {
            let base = l.position.x
            let x = CAKeyframeAnimation(keyPath: "position.x"); x.values = [base + dx, base - dx * 0.35, base + dx * 0.12, base]; x.keyTimes = [0, 0.35, 0.7, 1]
            let o = CAKeyframeAnimation(keyPath: "opacity"); o.values = [0.75, 0.5, 0.25, 0]; o.keyTimes = [0, 0.35, 0.7, 1]
            let g = CAAnimationGroup(); g.animations = [x, o]; g.duration = 0.6
            l.add(g, forKey: "split")
        }
        startLogoIdle(delay: 0.5)
    }

    /// Holographic scanlines drifting over the logo and a slow, small 3D sway.
    private func startLogoIdle(delay: Double) {
        fade(holoHost, to: 0.16, 0.8, delay: delay)
        let hm = CABasicAnimation(keyPath: "position.y"); hm.byValue = 4; hm.duration = 0.5; hm.repeatCount = .infinity
        holo.add(hm, forKey: "drift")
        var base = CATransform3DIdentity; base.m34 = -1 / 1100
        let tilt = CAKeyframeAnimation(keyPath: "transform")
        tilt.values = [0, 0.055, 0, -0.055, 0].map { NSValue(caTransform3D: CATransform3DRotate(base, $0, 0, 1, 0)) }
        tilt.duration = 7.2; tilt.repeatCount = .infinity; tilt.calculationMode = .cubic
        logoGroup.add(tilt, forKey: "tilt")
    }

    /// Light sweep across the logo surface.
    func logoSweep(duration: Double = 0.85) {
        sweepHost.opacity = 1
        let w = logoHost.bounds.width
        let a = CABasicAnimation(keyPath: "position.x"); a.fromValue = -240; a.toValue = w + 240; a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweepBand.position.x = w + 240
        sweepBand.add(a, forKey: "sweep")
    }

    /// 飛電インテリジェンス / アクセス承認 / お帰りなさいませ、社長
    func logoTitles(welcomeDelay: Double = 0.9) {
        fade(logoJP, to: 1, 0.35)
        flicker(logoJP)
        CATransaction.begin(); CATransaction.setAnimationDuration(0.5)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        logoRules.strokeEnd = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.grantJP.opacity = 1
            let g = CAAnimationGroup()
            let o = CAKeyframeAnimation(keyPath: "opacity"); o.values = [0, 1, 0.4, 1]; o.keyTimes = [0, 0.3, 0.5, 1]
            g.animations = [self.punch(from: 1.35, duration: 0.35), o]; g.duration = 0.35; g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.grantJP.add(g, forKey: "stamp")
            let r = CAAnimationGroup()
            let sc = CABasicAnimation(keyPath: "transform.scale"); sc.fromValue = 0.96; sc.toValue = 1.1
            let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0.9; op.toValue = 0
            r.animations = [sc, op]; r.duration = 0.7; r.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.stampRing.add(r, forKey: "ring")
        }
        fade(welcome, to: 1, 0.6, delay: welcomeDelay)
        fade(logoEN, to: 1, 0.6, delay: welcomeDelay + 0.3)
    }

    /// Skip: show the finished logo screen at once.
    func logoFinal() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in fragments + streaks { l.removeAllAnimations(); l.opacity = 0 }
        core.opacity = 0
        logoHost.opacity = 1; centerLight.opacity = 0.3
        for l in [logoJP, grantJP, welcome, logoEN] as [CALayer] { l.opacity = 1 }
        logoRules.strokeEnd = 1
        CATransaction.commit()
        flicker(logoHost)
        startLogoIdle(delay: 0)
    }

    // MARK: - Handoff

    /// Handoff: the screen breaks into hexagon tiles that flip away from the logo outward, revealing Codex behind.
    /// Each tile edge flashes lime as it turns. Driven frame by frame (no scheduled CA animations), so the screen and
    /// test snapshots show the same state.
    private struct HexTiles { let mask: CAShapeLayer, edges: CALayer, fill: CGPath; let tiles: [(center: CGPoint, edge: CAShapeLayer, delay: Double)]; let end: Double }
    private static let hexFlip = 0.3

    private func makeHexTiles(duration: Double) -> HexTiles {
        let b = root.bounds
        let c = viewPoint(stage: Boot.logoCenter)
        let R = max(34, min(b.width, b.height) / 22)
        let w = sqrt(3) * R, h = 1.5 * R
        func hex(_ r: CGFloat) -> CGPath {
            let p = CGMutablePath()
            for i in 0..<6 { let a = CGFloat(i) * .pi / 3 + .pi / 6; let pt = CGPoint(x: r * cos(a), y: r * sin(a)); i == 0 ? p.move(to: pt) : p.addLine(to: pt) }
            p.closeSubpath(); return p
        }
        var cells: [(CGPoint, CGFloat)] = []
        var row = 0, y = -R
        while y < b.height + R {
            var x = -w + (row % 2 == 0 ? 0 : w / 2)
            while x < b.width + w { cells.append((CGPoint(x: x, y: y), hypot(x - c.x, y - c.y))); x += w }
            y += h; row += 1
        }
        let maxD = max(1, cells.map { $0.1 }.max() ?? 1)
        let spread = duration * 0.7
        // The mask is ONE shape (union of the tiles still standing), so there are no seams between tiles.
        let maskL = CAShapeLayer(); maskL.frame = b; maskL.fillColor = NSColor.black.cgColor; maskL.fillRule = .nonZero
        let edges = CALayer(); edges.frame = b
        let fill = hex(R * 1.03), outline = hex(R * 0.96)
        var tiles: [(center: CGPoint, edge: CAShapeLayer, delay: Double)] = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (p, d) in cells {
            let e = CAShapeLayer(); e.path = outline; e.position = p
            e.fillColor = nil; e.strokeColor = Boot.lime.cgColor; e.lineWidth = 1.5; e.opacity = 0
            edges.addSublayer(e)
            tiles.append((p, e, Double(d / maxD) * spread))
        }
        CATransaction.commit()
        return HexTiles(mask: maskL, edges: edges, fill: fill, tiles: tiles, end: spread + Self.hexFlip + 0.12)
    }

    private func applyHex(_ h: HexTiles, at now: Double) {
        let flip = Self.hexFlip
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        for tile in h.tiles {
            let x = max(0, min(1, (now - tile.delay) / flip))
            let k = x * x                                   // ease-in: the tile turns faster as it goes
            if x < 1 {
                let t = CGAffineTransform(translationX: tile.center.x, y: tile.center.y).scaledBy(x: max(0.0001, 1 - k), y: 1 - 0.14 * k)
                path.addPath(h.fill, transform: t)
            }
            let ex = (now - tile.delay + 0.03) / 0.12         // short flash on the wave front (1-2 rings of tiles)
            let eo: Double = ex <= 0 || ex >= 1 ? 0 : (ex < 0.3 ? ex / 0.3 : (1 - ex) / 0.7)
            tile.edge.opacity = Float(0.75 * eo)
            tile.edge.transform = CATransform3DMakeScale(CGFloat(max(0.1, 1 - 0.9 * max(0, min(1, ex)))), 1, 1)
        }
        h.mask.path = path
        CATransaction.commit()
    }

    private var preparedHex: HexTiles?
    /// Builds the ~350 tiles ahead of time (during the logo screen), so the transition starts without a hitch.
    func prepareHex(duration: Double = 1.0) { if preparedHex == nil { preparedHex = makeHexTiles(duration: duration) } }

    func hexReveal(duration: Double = 1.0, completion: @escaping () -> Void) {
        let h = preparedHex ?? makeHexTiles(duration: duration)
        preparedHex = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.mask = h.mask
        (root.superlayer ?? root).addSublayer(h.edges)
        CATransaction.commit()
        applyHex(h, at: 0)
        let t0 = CACurrentMediaTime()
        var finished = false
        onFrame("hex") { [weak self] nowAbs in
            guard let self else { return }
            let now = nowAbs - t0
            self.applyHex(h, at: now)
            if now >= h.end && !finished {
                finished = true
                self.onFrame("hex", nil)
                h.edges.removeFromSuperlayer()
                completion()
            }
        }
    }

    /// Self-test: renders the hex transition at fixed times (independent of frame timing), then removes it.
    func hexPreview(times: [Double], dir: URL) {
        for (i, t) in times.enumerated() {
            let h = makeHexTiles(duration: 1.0)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            root.mask = h.mask; (root.superlayer ?? root).addSublayer(h.edges)
            CATransaction.commit()
            applyHex(h, at: t)
            snapshotView(to: dir.appendingPathComponent(String(format: "98_hex_%d_%03dms.png", i + 1, Int(t * 1000))), model: true)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            root.mask = nil; h.edges.removeFromSuperlayer()
            CATransaction.commit()
        }
    }

    /// After the handoff the launcher keeps running in the background: stop the frame clock and drop all layers.
    func releaseVisuals() {
        link?.invalidate(); link = nil
        frameHandlers.removeAll()
        timers.forEach { $0.invalidate() }; timers.removeAll()
        stopFlow()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.mask = nil
        stage.sublayers?.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        CATransaction.commit()
    }

    func clearForSkip() {
        timers.forEach { $0.invalidate() }; timers.removeAll()
        for l in [splash, login, ring] as [CALayer] { l.removeAllAnimations(); fade(l, to: 0, 0.2) }
        cards.removeAllAnimations(); cards.opacity = 0
    }

    // MARK: - Snapshot (self-test)

    /// Whole view including the handoff mask (presentation tree), for checking the hex transition.
    func snapshotView(to url: URL, model: Bool = false) {
        let b = root.bounds
        guard b.width > 0, let ctx = CGContext(data: nil, width: Int(b.width), height: Int(b.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor(red: 0.2, green: 0.1, blue: 0.3, alpha: 1).cgColor)   // stands in for Codex behind the window
        ctx.fill(CGRect(origin: .zero, size: b.size))
        (model ? root : (root.presentation() ?? root)).render(in: ctx)
        for l in root.superlayer?.sublayers ?? [] where l !== root { (model ? l : (l.presentation() ?? l)).render(in: ctx) }
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }

    func snapshot(to url: URL) {
        let w = Int(Boot.canvas.width), h = Int(Boot.canvas.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let saved = stage.transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.transform = CATransform3DIdentity
        CATransaction.commit()
        CATransaction.flush()
        // The presentation tree shows animations mid-flight; fall back to the model tree.
        if let p = stage.presentation() {
            ctx.translateBy(x: 0, y: 0)
            p.render(in: ctx)
        } else { stage.render(in: ctx) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.transform = saved
        CATransaction.commit()
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }
}
