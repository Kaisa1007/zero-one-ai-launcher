import AppKit

@main
enum Main {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// Borderless windows cannot become key by default; the boot window needs key events for Esc.
final class BootWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Click anywhere to skip.
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: BootWindow!
    private var stage: BootStage!
    private var director: BootDirector!
    private var keyMonitor: Any?
    private var terminationObserver: NSObjectProtocol?
    private var nap: NSObjectProtocol?
    private var selfTest: BootSelfTest?
    private let args = CommandLine.arguments
    private var windowed: Bool { args.contains("--windowed") || args.contains("--selftest") }

    func applicationDidFinishLaunching(_ note: Notification) {
        let assets = AssetStore()
        if !assets.missing.isEmpty { NSLog("ZeroOne: missing resources: \(assets.missing)") }
        stage = BootStage(assets: assets)
        director = BootDirector(assets: assets, stage: stage)
        nap = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "boot animation timing")

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = windowed ? NSRect(x: 0, y: 0, width: 1280, height: 800) : screen.frame
        window = BootWindow(contentRect: frame, styleMask: windowed ? [.titled, .closable, .resizable] : [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        if !windowed {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: true)
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        } else {
            window.center()
            window.title = "Zero-One Codex Boot"
        }
        let host = ClickCatcher(frame: NSRect(origin: .zero, size: frame.size))
        host.autoresizingMask = [.width, .height]
        stage.frame = host.bounds
        stage.autoresizingMask = [.width, .height]
        host.addSubview(stage)
        host.onClick = { [weak self] in if self?.selfTest == nil { self?.director.skip() } }   // the self-test ignores input
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if [53, 49, 36, 76].contains(e.keyCode) { if self.selfTest == nil { self.director.skip() }; return nil }   // Esc, Space, Return, Enter
            if e.modifierFlags.contains(.command) && e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            return e
        }

        director.onHandoff = { [weak self] reveal in
            guard let self else { return }
            NSApp.presentationOptions = []
            self.window.isOpaque = false
            self.window.backgroundColor = .clear
            reveal { [weak self] in self?.window.orderOut(nil) }
        }
        director.onFinished = { [weak self] keep in self?.finish(keepSkinning: keep) }

        if let i = args.firstIndex(of: "--selftest") {
            let out = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "zeroone-boot-test")
            selfTest = BootSelfTest(director: director, stage: stage, out: out)
            selfTest?.start()
            return
        }
        if let i = args.firstIndex(of: "--e2e-codex"), i + 1 < args.count {
            runCodexE2E(URL(fileURLWithPath: args[i + 1]))
            return
        }
        director.start()
    }

    /// After the reveal: stay in the background (no Dock icon) to keep skinning new Codex windows; quit with Codex.
    private func finish(keepSkinning: Bool) {
        NSCursor.unhide()
        stage.releaseVisuals()
        director.assets.purgeImages()
        if let n = nap { ProcessInfo.processInfo.endActivity(n); nap = nil }
        if director.codexMissing { askForCodex(); return }
        guard keepSkinning, let codex = director.codexApp else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if a?.processIdentifier == codex.processIdentifier { NSApp.terminate(nil) }
        }
        if codex.isTerminated { NSApp.terminate(nil) }
    }

    private func askForCodex() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "未找到 Codex（ChatGPT.app）"
        a.informativeText = "请选择 Codex 桌面应用。之后每次开机动画都会直接打开它。"
        a.addButton(withTitle: "选择 App…"); a.addButton(withTitle: "退出")
        if a.runModal() == .alertFirstButtonReturn, let url = director.launcher.chooseApp(for: .chatgpt) {
            director.launcher.launch(url) { _ in NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `--e2e-codex <out.png>`: real boot (windowed) with Codex launched, skinned, revealed; screenshot of the
    /// skinned Codex window, then Codex is quit again. Codex must not be running.
    private func runCodexE2E(_ out: URL) {
        guard let codex = director.launcher.resolve(.chatgpt)?.url else { print("E2E: Codex not found"); exit(2) }
        if director.launcher.isRunning(codex) { print("E2E: Codex already running, not touched"); exit(3) }
        director.audio.muted = true
        director.onFinished = { [weak self] keep in
            guard let self else { return }
            let app = self.director.codexApp
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.director.skinner.screenshot { data in
                    if let data { try? data.write(to: out) }
                    print(String(format: "E2E: done at %.1f s, Codex hidden=%@ active=%@, skinned windows %d, keep running %@, screenshot %@",
                                 self.director.elapsed, (app?.isHidden ?? true) ? "yes" : "no", (app?.isActive ?? false) ? "yes" : "no",
                                 self.director.skinner.skinnedWindows, keep ? "yes" : "no", data != nil ? "yes" : "no"))
                    app?.terminate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { fflush(stdout); exit(0) }
                }
            }
        }
        director.start()
    }
}
