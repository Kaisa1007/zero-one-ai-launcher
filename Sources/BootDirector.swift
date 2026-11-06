import AppKit
import QuartzCore

/// Runs the boot sequence, styled as logging in to the Hiden Intelligence corporate system (no henshin): login,
/// fingerprint, AUTHORIZE (SWF frame-script timing scan -> authorize -> standby), ZEA sync, then the Hiden logo
/// assembles and grants access. Codex is started hidden
/// and skinned in the background, and synchronisation only reaches 100 % once Codex has really rendered its
/// UI. Esc / Space / click skips to the final card.
final class BootDirector {
    let assets: AssetStore
    let audio: AudioDirector
    let stage: BootStage
    let launcher = AppLauncher()
    let skinner = CodexSkinner()

    /// No Codex launch (self-test); Codex counts as ready at this time.
    var previewReadyAt: Double?
    var onCue: ((String) -> Void)?
    /// Window handling for the reveal; called with a completion to run once the hole has opened.
    var onHandoff: ((_ reveal: @escaping (@escaping () -> Void) -> Void) -> Void)?
    var onFinished: ((_ keepRunning: Bool) -> Void)?

    private(set) var events: [(t: Double, what: String)] = []
    private var t0 = CACurrentMediaTime()
    private var run = 0
    private(set) var codexApp: NSRunningApplication?
    private var codexURL: URL?
    private(set) var codexReady = false
    private(set) var codexSkinned = false
    private var codexAlreadyRunning = false
    private(set) var codexMissing = false
    private var guardian: HiddenGuard?
    private var syncStart: CFTimeInterval = 0
    private var syncValue = 0.0
    private var inFinale = false
    private var skipped = false
    private var finished = false

    static let minSync = 6.0
    static let readyTimeout = 30.0   // seconds after launch
    /// Level of the authorisation moment (scan + Authorize voice), about -3 dB.
    static let authorizeGain: Float = 0.7   // seconds of synchronisation before PROGRISE, even when Codex is ready early

    init(assets: AssetStore, stage: BootStage) {
        self.assets = assets
        self.stage = stage
        audio = AudioDirector(assets: assets)
        audio.onEvent = { [weak self] e in self?.log(e) }
        launcher.onAction = { [weak self] e in self?.log(e) }
        skinner.onLog = { [weak self] e in self?.log(e) }
    }

    var elapsed: Double { CACurrentMediaTime() - t0 }

    func log(_ s: String) {
        events.append((elapsed, s))
        if ProcessInfo.processInfo.environment["ZEROONE_LOG"] != nil || CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
            print(String(format: "[%7.3f] %@", elapsed, s))
        }
    }

    private func cue(_ name: String) {
        log("cue \(name)"); onCue?(name)
        let phase = ["power": "boot", "login": "login", "scan": "scan+auth", "sync": "sync", "sync100": "logo", "handoff": "handoff"][name]
        if let phase { stage.perfPhase = phase }
    }

    /// System voice line (Assets/14_Voice) on its own channel; skipped silently if the line is not bundled.
    private func say(_ name: String) { let id = "voice_" + name; if audio.has(id) { audio.play(id, on: .announce, gain: 0.95) } }

    /// Runs `block` after `t` seconds unless the sequence was skipped meanwhile.
    /// Strict timers: GCD's default leeway (a few % of the delay) would drift the SWF-timed cues.
    private var timerRefs: [ObjectIdentifier: DispatchSourceTimer] = [:]
    private func after(_ t: Double, _ block: @escaping () -> Void) {
        let r = run
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        let id = ObjectIdentifier(timer)
        timer.schedule(deadline: .now() + max(0, t), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            timer.cancel()
            guard let self else { return }
            self.timerRefs[id] = nil
            guard self.run == r else { return }
            block()
        }
        timerRefs[id] = timer
        timer.resume()
    }

    // MARK: - Codex

    private func startCodex() {
        if let at = previewReadyAt {
            log("preview: Codex simulated ready at \(at) s")
            after(at) { [weak self] in self?.markReady("CODEX 画面　準備完了（プレビュー）") }
            return
        }
        guard let url = launcher.resolve(.chatgpt)?.url else {
            codexMissing = true; codexReady = true
            log("Codex not found")
            return
        }
        codexURL = url
        if launcher.isRunning(url) {
            codexAlreadyRunning = true; codexReady = true
            log("Codex already running: no skin this time")
            codexApp = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: url)?.bundleIdentifier ?? "").first
            return
        }
        let keep: (NSRunningApplication?) -> Void = { [weak self] app in
            guard let self, let app else { return }
            self.codexApp = app
            let g = HiddenGuard(app: app)
            g.onLog = { [weak self] m in self?.log(m) }
            g.onSurfaced = { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.stage.window?.makeKeyAndOrderFront(nil)
            }
            self.guardian = g
        }
        if CodexSkinner.isCodex(url), let script = CodexSkinner.script(accent: Boot.lime, resources: assets.resourceURL) {
            codexSkinned = true
            skinner.launch(url, script: script) { [weak self] app in
                keep(app)
                // Never hang at 99 %: after `readyTimeout` the handoff goes ahead with whatever Codex shows.
                self?.skinner.waitUntilReady(timeout: Self.readyTimeout) { [weak self] ok in
                    self?.markReady(ok ? "CODEX 画面　準備完了" : "CODEX　応答待ち超過・続行")
                }
            }
        } else {
            launcher.prelaunch(url) { [weak self] app in
                keep(app)
                func poll() {
                    guard let self else { return }
                    if app?.isFinishedLaunching ?? true { self.markReady("CODEX　起動完了") }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll) }
                }
                poll()
            }
        }
    }

    private func markReady(_ line: String) {
        guard !codexReady else { return }
        codexReady = true
        stage.addLog(line, highlight: true)
        log("codex ready")
    }

    // MARK: - Sequence

    /// Employee record typed into the login panel.
    static let profile: [(String, Double)] = [
        ("HI-0001", 3.55), ("飛電 或人", 4.0), ("代表取締役社長", 4.45), ("レベル01　全権限", 4.95), ("CODEX 作業端末　Mac", 5.5)]
    static let scanAt = 6.45

    func start() {
        t0 = CACurrentMediaTime()
        log("boot start")
        log(String(format: "images decoded in %.0f ms", assets.decodeTime * 1000))
        startCodex()
        stage.startClock()
        stage.setStatus("起動中")

        // 0.0 power on
        cue("power")
        audio.play(.boot)
        stage.powerOn()
        after(0.35) { [weak self] in self?.stage.addLog("飛電インテリジェンス　システム起動"); self?.audio.play(.tick) }

        // 0.6 corporate splash, module check
        after(0.6) { [weak self] in
            guard let self else { return }
            self.cue("logo")
            self.stage.showSplash(duration: 2.2)
            self.after(0.1) { [weak self] in self?.say("boot") }
            for i in 0..<self.stage.panelCount { self.after(Double(i) * 0.06) { [weak self] in self?.stage.setPanel(i, .blink) } }
            self.after(0.9) { [weak self] in for i in 0..<(self?.stage.panelCount ?? 0) { self?.stage.setPanel(i, .off) } }
        }
        after(1.3) { [weak self] in self?.stage.addLog("社内ネットワーク　接続完了"); self?.stage.setPanel(0, .on); self?.audio.play(.tick) }
        after(2.0) { [weak self] in self?.stage.addLog("衛星ゼア　応答良好"); self?.stage.setPanel(1, .on); self?.audio.play(.tick) }
        after(2.6) { [weak self] in self?.stage.addLog("暗号通信　AES-256 確立"); self?.stage.setPanel(2, .on); self?.audio.play(.tick) }

        // 3.0 employee login
        after(3.0) { [weak self] in
            guard let self else { return }
            self.stage.hideSplash()
            self.after(0.2) { [weak self] in
                guard let self else { return }
                self.cue("login")
                self.stage.openLogin()
                self.after(0.25) { [weak self] in self?.say("login") }   // after the boot line has finished
                self.stage.setStatus("ログイン")
                self.stage.setPanel(3, .blink)
                self.stage.setAuthLine("認証情報を入力中…", color: Boot.lime.withAlphaComponent(0.6))
                self.audio.play(.panel)
            }
        }
        for (i, (value, at)) in Self.profile.enumerated() {
            after(at) { [weak self] in self?.stage.typeField(i, value) { [weak self] in self?.audio.play(.type) } }
        }
        after(Self.scanAt - 0.45) { [weak self] in
            self?.cue("contact")
            self?.stage.fingerprintContact()
            self?.stage.setAuthLine("指紋センサーに接触")
            self?.audio.play(.tick)
        }
        after(Self.scanAt - 0.05) { [weak self] in self?.stage.setPanel(3, .on) }
        after(Self.scanAt) { [weak self] in self?.authorize() }
    }

    /// Fingerprint scan, AUTHORIZE (SWF 1957: scan -> authorize 19 f, -> standby 48 f).
    private func authorize() {
        cue("scan")
        audio.play("driver_scan", on: .scan, gain: Self.authorizeGain)
        stage.fingerprintScan(duration: Geo.authorizeAfterScan + 0.05) { [weak self] _ in self?.audio.play(.lock) }
        stage.setScanLabel("生体認証　照合中")
        stage.setAuthLine("指紋照合中…")
        stage.setPanel(4, .blink)
        stage.addLog("生体認証　照合開始")
        after(Geo.authorizeAfterScan) { [weak self] in
            guard let self else { return }
            self.cue("authorize")
            self.audio.play(Boot.authorizeClip, on: .voice, gain: Self.authorizeGain)
            self.after(Geo.standbyAfterScan - Geo.authorizeAfterScan) { [weak self] in self?.beginSync() }
            self.stage.authorizedFlash()
            self.stage.setAuthLine("認証完了　ようこそ、社長", color: .white)
            self.stage.setScanLabel("照合一致　本人確認済")
            self.stage.card("認証", sub: "AUTHORIZE", tag: "飛電インテリジェンス　社長認証", style: .limeWipe, hold: 0.85)
            self.audio.play(.swish)
            self.stage.setPanel(4, .on); self.stage.setPanel(5, .on)
            self.stage.addLog("認証　承認", highlight: true)
        }
    }

    /// Standby loop + ZEA synchronisation ring. Reaches 100 % only when Codex is ready and minSync has passed.
    private func beginSync() {
        cue("sync")
        stage.closeLogin()
        audio.play("driver_standby", on: .standby, loop: true, gain: 0.4)
        audio.play(.chatter, loop: true)
        stage.showRing(true)
        stage.setStatus(codexAlreadyRunning ? "起動済み" : (codexMissing ? "未検出" : "接続中"))
        stage.addLog("衛星ゼア　同期開始")
        after(0.3) { [weak self] in self?.say("sync") }   // the Authorize voice has ended by then
        after(1.2) { [weak self] in
            guard let self else { return }
            self.stage.addLog(self.codexSkinned ? "CODEX　飛電テーマ適用" : "CODEX　待機中")
        }
        syncStart = CACurrentMediaTime()
        syncPlan = nil
        waitingShown = false
        lastRise = 0; stallLogged = false
        syncSpeed = 0; syncLastT = 0; syncValue = 0
        let r = run
        stage.onFrame("sync") { [weak self] _ in
            guard let self else { return }
            guard self.run == r else { self.stage.onFrame("sync", nil); return }
            self.tickSync()
        }
    }

    // MARK: Sync progress
    // Uniform speed: 100 % over minSync, integrated from real elapsed time (frame drops do not change the speed).
    // Only if Codex is still not ready at 90 % does the speed ease (0.3 s) down to a slow crawl ("応答待ち"), and back
    // up to the same uniform speed once it is ready. Speed changes are smoothed, so there is never a jump or a stop.
    private var syncPlan: Bool?          // non-nil once Codex is ready during the sync (kept for the stall check)
    private var waitingShown = false
    private var syncSpeed = 0.0, syncLastT = 0.0
    private var lastRise = 0.0, stallLogged = false
    static let crawlFrom = 90.0, crawlSpeed = 0.8   // % and %/s

    private func tickSync() {
        stage.syncFX()
        let e = CACurrentMediaTime() - syncStart
        let dt = max(0, min(0.1, e - syncLastT)); syncLastT = e
        let uniform = 100 / Self.minSync
        if codexReady && syncPlan == nil { syncPlan = true }
        let target = (!codexReady && syncValue >= Self.crawlFrom) ? Self.crawlSpeed : uniform
        // Exact uniform speed from the first frame; only a change of target speed is eased (time constant 0.3 s).
        syncSpeed = syncSpeed == 0 ? target : syncSpeed + (target - syncSpeed) * (1 - exp(-dt / 0.3))
        var next = syncValue + syncSpeed * dt
        if !codexReady { next = min(next, 99) }
        next = min(100, next)
        if next > syncValue + 0.0001 { lastRise = e }
        if syncPlan != nil, e - lastRise > 0.25, !stallLogged { stallLogged = true; log(String(format: "sync stall at %.1f%%", next)) }
        syncValue = next
        stage.setSync(syncValue)
        if !codexReady, syncValue >= Self.crawlFrom, !waitingShown {
            waitingShown = true
            stage.addLog("CODEX 画面の準備を待機中…")
            stage.setStatus("応答待ち")
        }
        let lit = Int(syncValue / 100 * 6.0)
        for i in 0..<min(6, lit) { stage.setPanel(6 + i, .on) }
        if lit < 6 { stage.setPanel(6 + lit, .blink) }
        if codexReady && syncValue >= 100 {
            stage.onFrame("sync", nil)
            syncComplete()
        }
    }

    private func syncComplete() {
        cue("sync100")
        stage.setSync(100)
        stage.ringFlash()
        for i in 6..<12 { stage.setPanel(i, .on) }
        audio.stop(.chatter, fade: 0.2)
        audio.play(.granted)
        say("sync_done")
        stage.addLog("同期率　100%", highlight: true)
        after(0.5) { [weak self] in self?.logoSequence() }
    }

    /// The ring collapses to a point, light and hex fragments converge, the Hiden logo assembles,
    /// a light sweep crosses it, then アクセス承認 / お帰りなさいませ、社長.
    private func logoSequence() {
        stage.showRing(false)
        stage.setStatus("承認処理中")
        stage.addLog("飛電システム　最終承認")
        audio.stop(.standby, fade: 0.9)
        after(0.4) { [weak self] in
            guard let self else { return }
            self.cue("converge")
            self.audio.play(.converge)
            self.stage.logoConverge(duration: 1.3)
        }
        after(1.7) { [weak self] in
            guard let self else { return }
            self.cue("logoForm")
            self.audio.play(.boom)
            self.stage.logoForm()
        }
        after(2.4) { [weak self] in
            self?.cue("sweep")
            self?.audio.play(.shimmer)
            self?.stage.logoSweep()
        }
        // Voice: アクセス承認 on the stamp, then お帰りなさいませ、社長 with its line; the handoff waits for the words.
        let titlesAt = 2.9, stampAt = titlesAt + 0.35
        let welcomeAt = stampAt + (audio.has("voice_granted") ? audio.speechEnd("voice_granted") + 0.12 : 0.55)
        let finaleAt = max(6.3, audio.has("voice_welcome") ? welcomeAt + audio.speechEnd("voice_welcome") + 0.15 : 6.3)
        after(titlesAt) { [weak self] in
            guard let self else { return }
            self.cue("titles")
            self.stage.logoTitles(welcomeDelay: welcomeAt - titlesAt)
            self.after(0.35) { [weak self] in self?.audio.play(.slam); self?.say("granted") }
            self.after(welcomeAt - titlesAt) { [weak self] in self?.say("welcome") }
            self.after(1.2) { [weak self] in self?.stage.prepareHex(duration: 1.0) }   // tiles ready before the handoff
            self.stage.setStatus(self.codexMissing ? "CODEX 未検出" : "アクセス承認")
            self.stage.addLog("アクセス承認　お帰りなさいませ、社長", highlight: true)
        }
        after(finaleAt) { [weak self] in self?.finale() }
    }

    // MARK: - Finale / handoff

    /// Waits for Codex (normally ready long before), then hands off.
    private func finale() {
        guard !inFinale else { return }
        inFinale = true
        cue("finale")
        stage.onFrame("sync", nil)
        if codexReady { handoff() } else {
            stage.addLog("CODEX 画面の準備を待機中…")
            func poll() { if codexReady { handoff() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: poll) } }
            poll()
        }
    }

    private func handoff() {
        guard !finished else { return }
        finished = true
        cue("handoff")
        stage.stopClock()
        guardian?.stop(); guardian = nil
        codexApp?.unhide()
        if let url = codexURL, !codexMissing { launcher.launch(url) { [weak self] e in if let e { self?.log("activate error \(e.localizedDescription)") } } }
        audio.play(.flip); audio.play(.whoosh)
        onHandoff? { [weak self] done in
            self?.stage.hexReveal(duration: 1.0) { [weak self] in
                guard let self else { return }
                self.log("revealed")
                for line in self.stage.perfReport() { self.log("frames " + line) }
                done()
                self.onFinished?(self.codexSkinned && self.skinner.isAttached)
            }
        }
    }

    /// Esc / Space / click: jump to the finished logo screen (still waits for Codex to be ready).
    /// A second skip while waiting forces the handoff.
    func skip() {
        guard !finished else { return }
        if inFinale {
            if !codexReady { log("skip: forcing handoff"); markReady("CODEX　社長権限で強制接続") }
            return
        }
        log("skip")
        skipped = true
        run += 1
        stage.onFrame("sync", nil)
        audio.stopAll(fade: 0.25)
        stage.clearForSkip()
        stage.logoFinal()
        audio.play(.slam)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.finale() }
    }
}
