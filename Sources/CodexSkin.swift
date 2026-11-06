import AppKit

/// Chrome DevTools Protocol over Chromium's private `--remote-debugging-pipe` (fd 3 in, fd 4 out, NUL-separated
/// JSON). No network port is opened, so nothing but this launcher can talk to the app.
final class CDPPipe {
    let pid: pid_t
    private let wfd: Int32
    private let rfd: Int32
    private var nextId = 1
    private var callbacks: [Int: ([String: Any]) -> Void] = [:]
    var onEvent: ((String, [String: Any], String?) -> Void)?   // method, params, sessionId
    var onClose: (() -> Void)?
    private(set) var closed = false

    init?(executable: String, arguments: [String]) {
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0 else { return nil }
        // Keep our ends away from 3/4 so the dup2 in the child cannot collide with them.
        for i in 0..<2 {
            let a = fcntl(toChild[i], F_DUPFD, 10); close(toChild[i]); toChild[i] = a
            let b = fcntl(fromChild[i], F_DUPFD, 10); close(fromChild[i]); fromChild[i] = b
        }
        fcntl(toChild[1], F_SETFD, FD_CLOEXEC); fcntl(fromChild[0], F_SETFD, FD_CLOEXEC)
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, toChild[0], 3)
        posix_spawn_file_actions_adddup2(&fa, fromChild[1], 4)
        for fd in [toChild[0], toChild[1], fromChild[0], fromChild[1]] { posix_spawn_file_actions_addclose(&fa, fd) }
        var p: pid_t = 0
        let argv = [executable] + arguments
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let rc = posix_spawn(&p, executable, &fa, nil, &cargs, environ)
        cargs.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fa)
        close(toChild[0]); close(fromChild[1])
        guard rc == 0 else { close(toChild[1]); close(fromChild[0]); return nil }
        pid = p; wfd = toChild[1]; rfd = fromChild[0]
        startReader()
    }

    private func startReader() {
        let fd = rfd
        Thread { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let z = buffer.firstIndex(of: 0) {
                    let msg = buffer[buffer.startIndex..<z]
                    buffer.removeSubrange(buffer.startIndex...z)
                    if let o = try? JSONSerialization.jsonObject(with: msg) as? [String: Any] {
                        DispatchQueue.main.async { self?.dispatch(o) }
                    }
                }
            }
            DispatchQueue.main.async { self?.finish() }
        }.start()
    }

    private func dispatch(_ o: [String: Any]) {
        if let id = o["id"] as? Int, let cb = callbacks.removeValue(forKey: id) { cb(o); return }
        if let m = o["method"] as? String { onEvent?(m, o["params"] as? [String: Any] ?? [:], o["sessionId"] as? String) }
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil, reply: (([String: Any]) -> Void)? = nil) -> Int {
        guard !closed else { return -1 }
        let id = nextId; nextId += 1
        var m: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { m["sessionId"] = session }
        guard var d = try? JSONSerialization.data(withJSONObject: m) else { return -1 }
        d.append(0)
        if let reply { callbacks[id] = reply }
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count { let n = write(wfd, p.baseAddress! + off, d.count - off); if n <= 0 { break }; off += n }
        }
        return id
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        close(wfd); close(rfd)
        callbacks.removeAll()
        onClose?()
    }

    /// Closing the pipe does not quit the app (verified): the skin already injected stays on screen.
    func detach() { finish() }
}

/// Starts the Codex desktop app (ChatGPT.app, com.openai.codex) through the private pipe and injects the
/// Zero-One skin into every app window. Nothing in the app bundle is modified; when the launcher is not
/// running, Codex simply looks normal again after its next reload.
final class CodexSkinner {
    static let bundleID = "com.openai.codex"
    private(set) var pipe: CDPPipe?
    private var sessions: [String: String] = [:]   // targetId -> sessionId
    private var urls: [String: String] = [:]       // targetId -> url
    private var darkened = Set<String>()           // embedded views told to use dark mode
    private var script = ""
    var onLog: ((String) -> Void)?
    var dryRun = false

    static func isCodex(_ url: URL) -> Bool { Bundle(url: url)?.bundleIdentifier == bundleID }

    /// Builds the injected script from Resources/Skin with the key's accent colour.
    static func script(accent: NSColor, resources: URL) -> String? {
        let skin = resources.appendingPathComponent("Skin")
        guard var css = try? String(contentsOf: skin.appendingPathComponent("codex_skin.css"), encoding: .utf8),
              let js = try? String(contentsOf: skin.appendingPathComponent("codex_skin.js"), encoding: .utf8) else { return nil }
        let c = accent.usingColorSpace(.sRGB) ?? accent
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        let hex = String(format: "%02x%02x%02x", r, g, b)
        let logo = (try? Data(contentsOf: resources.appendingPathComponent("Images/hiden_logo_vec@3x.png")))
            .map { "data:image/png;base64," + $0.base64EncodedString() } ?? ""
        css = css.replacingOccurrences(of: "{{ACCENT}}", with: "#" + hex)
            .replacingOccurrences(of: "{{ACCENT_NOHASH}}", with: hex)
            .replacingOccurrences(of: "{{ACCENT_RGB}}", with: "\(r), \(g), \(b)")
            .replacingOccurrences(of: "{{LOGO_URL}}", with: logo)
        guard let cssJSON = try? JSONSerialization.data(withJSONObject: [css]),
              let arr = String(data: cssJSON, encoding: .utf8) else { return nil }
        let literal = String(arr.dropFirst().dropLast())   // the JSON string literal for the CSS
        return js.replacingOccurrences(of: "{{CSS_JSON}}", with: literal)
    }

    /// Launches Codex with the pipe and keeps skinning its windows. `completion` gets the running app.
    func launch(_ url: URL, script: String, completion: @escaping (NSRunningApplication?) -> Void) {
        if dryRun {
            onLog?("skin launch \(url.path) (dry run)")
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard let exe = Bundle(url: url)?.executableURL?.path,
              let p = CDPPipe(executable: exe, arguments: ["--remote-debugging-pipe"]) else {
            onLog?("skin launch failed")
            completion(nil)
            return
        }
        self.script = script
        pipe = p
        sessions = [:]
        darkened = []
        onLog?("skin launch \(url.path) pid \(p.pid)")
        p.onEvent = { [weak self] method, params, _ in
            guard let self else { return }
            if method == "Target.targetCreated" || method == "Target.targetInfoChanged",
               let info = params["targetInfo"] as? [String: Any] { self.consider(info) }
            if method == "Target.detachedFromTarget", let t = params["targetId"] as? String { self.sessions[t] = nil }
        }
        p.onClose = { [weak self] in
            self?.onLog?("skin pipe closed")
            self?.pipe = nil
            self?.sessions = [:]
            self?.darkened = []
        }
        p.send("Target.setDiscoverTargets", ["discover": true])
        p.send("Target.getTargets") { [weak self] r in
            for info in ((r["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]]) ?? [] { self?.consider(info) }
        }
        // The NSRunningApplication appears a moment after the spawn.
        var tries = 0
        func find() {
            if let app = NSRunningApplication(processIdentifier: p.pid) { completion(app); return }
            tries += 1
            if tries > 60 { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: find)
        }
        find()
    }

    /// App windows are "page" targets served from app://-/ (main window and detached windows).
    private func consider(_ info: [String: Any]) {
        guard let p = pipe, let type = info["type"] as? String, let id = info["targetId"] as? String else { return }
        let url = (info["url"] as? String) ?? ""
        // Embedded views (inline visualisations, web panels) follow the system appearance on their own. With macOS in
        // light mode they would draw dark text onto the skin's dark background, so they are told the system is dark.
        if type == "webview" || type == "iframe" {
            guard !darkened.contains(id) else { return }
            darkened.insert(id)
            p.send("Target.attachToTarget", ["targetId": id, "flatten": true]) { r in
                guard let s = (r["result"] as? [String: Any])?["sessionId"] as? String else { return }
                p.send("Emulation.setEmulatedMedia", ["features": [["name": "prefers-color-scheme", "value": "dark"]]], session: s)
            }
            return
        }
        guard type == "page", sessions[id] == nil, url.hasPrefix("app://") else { return }
        sessions[id] = "pending"
        urls[id] = info["url"] as? String
        p.send("Target.attachToTarget", ["targetId": id, "flatten": true]) { [weak self] r in
            guard let self, let s = (r["result"] as? [String: Any])?["sessionId"] as? String else { self?.sessions[id] = nil; return }
            self.sessions[id] = s
            p.send("Page.enable", session: s)
            p.send("Emulation.setEmulatedMedia", ["features": [["name": "prefers-color-scheme", "value": "dark"]]], session: s)
            // Reloads keep the skin while the launcher runs; the evaluate covers the page as it is now.
            p.send("Page.addScriptToEvaluateOnNewDocument", ["source": self.script], session: s)
            self.apply(session: s, label: String(((info["url"] as? String) ?? "").prefix(40)), attempt: 0)
        }
    }

    /// Evaluates the skin in a window; retries while the page is still being created or the script failed.
    private func apply(session s: String, label: String, attempt: Int) {
        guard let p = pipe else { return }
        p.send("Runtime.evaluate", ["expression": script, "returnByValue": true], session: s) { [weak self] r in
            guard let self else { return }
            let res = r["result"] as? [String: Any]
            let v = (res?["result"] as? [String: Any])?["value"] as? String
            let exc = ((res?["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any])?["description"] as? String
            if v == "on" || v == "updated" || v == "pending" {
                self.onLog?("skin applied to \(label): \(v!)")
            } else if attempt < 30 {
                if attempt == 0 { self.onLog?("skin retry \(label): \(exc?.split(separator: "\n").first.map(String.init) ?? "no result")") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.apply(session: s, label: label, attempt: attempt + 1) }
            } else {
                self.onLog?("skin failed on \(label)")
            }
        }
    }

    /// Re-themes open windows (accent change) or removes the skin.
    func update(script: String?) {
        guard let p = pipe else { return }
        if let script { self.script = script }
        for (_, s) in sessions where s != "pending" {
            p.send("Runtime.evaluate", ["expression": script ?? "window.__zoSkinOff && window.__zoSkinOff()"], session: s)
        }
    }

    var isAttached: Bool { pipe != nil }

    /// Self-test: screenshot of the first skinned window.
    func screenshot(_ completion: @escaping (Data?) -> Void) {
        let main = sessions.first { $0.value != "pending" && (urls[$0.key] ?? "").hasSuffix("/index.html") }
        guard let p = pipe, let s = (main ?? sessions.first { $0.value != "pending" })?.value else { completion(nil); return }
        p.send("Page.captureScreenshot", ["format": "png"], session: s) { r in
            completion(((r["result"] as? [String: Any])?["data"] as? String).flatMap { Data(base64Encoded: $0) })
        }
    }
    /// Polls the main window until Codex has rendered its app layout (not the loading splash).
    func waitUntilReady(timeout: Double, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            let main = sessions.first { $0.value != "pending" && (urls[$0.key] ?? "").hasSuffix("/index.html") }
            guard let p = pipe, let s = main?.value else {
                if Date() > deadline || pipe == nil { completion(false) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check) }
                return
            }
            // Checked on the page itself, so a skin problem can never block the handoff. Re-applies a missing skin.
            let probe = "JSON.stringify({ready: !!document.querySelector('[class*=\"_PageSurfaceLayout_\"], [class*=\"PageSurfaceLayout-\"]') || (!!document.querySelector('main') && !!document.querySelector('[data-composer-markdown], main [contenteditable=\"true\"], [contenteditable=\"true\"].ProseMirror, textarea')), skin: !!window.__zoSkin})"   // no dependency on class names: main area + composer
            p.send("Runtime.evaluate", ["expression": probe, "returnByValue": true], session: s) { [weak self] r in
                let json = ((r["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String
                let o = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Bool] } ?? [:]
                let ok = o["ready"] ?? false
                if ok, o["skin"] == false, let self { self.onLog?("skin missing on ready page, re-applying"); self.apply(session: s, label: "main", attempt: 0) }
                if ok { completion(true) }
                else if Date() > deadline { completion(false) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check) }
            }
        }
        check()
    }

    var skinnedWindows: Int { sessions.values.filter { $0 != "pending" }.count }
}
