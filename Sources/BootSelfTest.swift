import AppKit

/// `--selftest <dir>`: the whole boot in a window, muted, without Codex (it counts as ready after 7 s).
/// Snapshots at each beat, checks the audio order, the sync rule and the length, then quits (0 = pass).
@MainActor
final class BootSelfTest {
    let director: BootDirector, stage: BootStage, out: URL
    private var failures: [String] = [], notes: [String] = []
    static let shots: [String: Double] = ["logo": 1.2, "login": 2.4, "contact": 0.35, "scan": 0.45, "authorize": 0.35, "sync": 2.5, "sync100": 0.1,
                                          "converge": 0.8, "logoForm": 0.35, "sweep": 0.45, "titles": 1.6]
    init(director: BootDirector, stage: BootStage, out: URL) {
        self.director = director; self.stage = stage; self.out = out
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    func start() {
        director.audio.muted = true
        // ZEROONE_READY_AT simulates a slower Codex (seconds after start); default 7 s.
        director.previewReadyAt = Double(ProcessInfo.processInfo.environment["ZEROONE_READY_AT"] ?? "") ?? 7
        var n = 0
        director.onCue = { [weak self] name in
            guard let self else { return }
            if name == "titles" {
                // Hex transition frames at fixed times, rendered over the finished titles screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { self.stage.hexPreview(times: [0.15, 0.4, 0.65, 0.9], dir: self.out) }
            }
            guard let d = Self.shots[name] else { return }
            n += 1
            let file = String(format: "%02d_%@.png", n, name)
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { self.stage.snapshot(to: self.out.appendingPathComponent(file)) }
        }
        director.onFinished = { [weak self] _ in self?.finish() }
        director.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.failures.append("TIMEOUT"); self?.finish() }
    }

    private func t(_ prefix: String) -> Double? { director.events.first { $0.what.hasPrefix(prefix) }?.t }

    private func finish() {
        let voice = { (n: String) -> [String] in self.director.audio.has("voice_" + n) ? ["play voice_" + n] : [] }
        let order = voice("boot") + voice("login") + ["play driver_scan", "play authorize_common", "play driver_standby"]
                  + voice("sync") + voice("sync_done") + voice("granted") + voice("welcome")
        // Voice lines never overlap each other, and the first sync line starts after the Authorize voice.
        let voiceLines = ["boot", "login", "sync", "sync_done", "granted", "welcome"].filter { director.audio.has("voice_" + $0) }
        for (a, b) in zip(voiceLines, voiceLines.dropFirst()) {
            if let ta = t("play voice_" + a), let tb = t("play voice_" + b), tb < ta + director.audio.speechEnd("voice_" + a) - 0.02 {
                failures.append("voice \(a) overlaps \(b)")
            }
        }
        if let au = t("play authorize_common"), let vs = t("play voice_sync"), vs < au + director.audio.audibleEnd("authorize_common") { failures.append("sync voice overlaps Authorize") }
        if !voiceLines.isEmpty { notes.append("voice lines: " + voiceLines.joined(separator: ", ")) }
        let times = order.map { t($0) }
        for (o, v) in zip(order, times) {
            let c = director.events.filter { $0.what.hasPrefix(o + " ") }.count
            if c != 1 { failures.append("\(o) played \(c) times") }
            if v == nil { failures.append("\(o) missing") }
        }
        let ts = times.compactMap { $0 }
        if ts != ts.sorted() { failures.append("voice clips out of order") }
        if let s = t("play driver_scan"), let a = t("play authorize_common") {
            notes.append(String(format: "scan -> authorize %.3f s (SWF 0.633)", a - s))
            if abs(a - s - Geo.authorizeAfterScan) > 0.06 { failures.append("authorize timing") }
        }
        if let r = t("codex ready"), let s100 = t("cue sync100"), let s0 = t("cue sync") {
            notes.append(String(format: "sync started %.2f s, Codex ready %.2f s, sync 100%% at %.2f s", s0, r, s100))
            if s100 < r { failures.append("sync reached 100% before Codex was ready") }
            if s100 - s0 < BootDirector.minSync - 0.05 { failures.append("sync shorter than minimum") }
        } else { failures.append("sync cues missing") }
        if let st = director.events.first(where: { $0.what.hasPrefix("sync stall") }) { failures.append(st.what) }
        // Every animation (explicit and implicit) must be locked to 60 fps.
        let probe = CALayer(); stage.stage.addSublayer(probe)
        CATransaction.flush()   // a layer only gets implicit animations once it has been committed
        let explicit = CABasicAnimation(keyPath: "opacity"); explicit.duration = 1; probe.add(explicit, forKey: "p")
        CATransaction.begin(); CATransaction.setAnimationDuration(1); probe.opacity = 0.5; CATransaction.commit()
        let rates = ["p", "opacity"].compactMap { probe.animation(forKey: $0)?.preferredFrameRateRange.preferred }
        probe.removeFromSuperlayer()
        notes.append("animation frame rate: " + rates.map { String(format: "%.0f", $0 ?? 0) }.joined(separator: ", ") + " fps")
        if rates.count != 2 || rates.contains(where: { $0 != BootStage.fps }) { failures.append("animations not locked to the frame clock rate") }
        if let h = t("cue handoff") {
            notes.append(String(format: "handoff at %.2f s", h))
            if h < 20 || h > 30 { failures.append(String(format: "length %.1f s outside 20-30 s", h)) }
        } else { failures.append("no handoff") }
        var lines = ["Zero-One Codex boot self-test", ""] + notes + ["", failures.isEmpty ? "RESULT: PASS" : "RESULT: FAIL"] + failures
        lines += ["", "---- events ----"] + director.events.map { String(format: "%8.3f  %@", $0.t, $0.what) }
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("selftest.log"), atomically: true, encoding: .utf8)
        print(failures.isEmpty ? "SELFTEST PASS" : "SELFTEST FAIL\n" + failures.joined(separator: "\n"))
        notes.forEach { print("  " + $0) }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}
