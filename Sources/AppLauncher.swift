import AppKit
import UniformTypeIdentifiers

enum TargetApp: String, CaseIterable, Codable {
    case chatgpt, claude

    var displayName: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    var bundleFileName: String { "\(displayName).app" }
    /// Identifiers read from the apps installed on the development Mac (Info.plist),
    /// not guessed. Name lookup and a user-chosen .app cover other setups.
    var observedBundleIDs: [String] {
        self == .chatgpt ? ["com.openai.codex"] : ["com.anthropic.claudefordesktop"]
    }
    var defaultsKey: String { "appOverride.\(rawValue)" }
}

struct ResolvedApp {
    let url: URL
    let source: String
}

/// Keeps a prelaunched app hidden until `stop()`: Electron-style apps (ChatGPT, Claude) show their window
/// themselves once they finish launching, even when started with `hides = true`. Every time the app
/// unhides or activates, it is hidden again and focus is handed back to the launcher.
final class HiddenGuard {
    let app: NSRunningApplication
    private var observations: [NSKeyValueObservation] = []
    private var notes: [NSObjectProtocol] = []
    private var timer: Timer?
    private(set) var surfaced = 0
    var onSurfaced: (() -> Void)?
    var onLog: ((String) -> Void)?

    init(app: NSRunningApplication) {
        self.app = app
        let poke: () -> Void = { [weak self] in DispatchQueue.main.async { self?.enforce() } }
        observations.append(app.observe(\.isHidden, options: [.new]) { _, _ in poke() })
        observations.append(app.observe(\.isActive, options: [.new]) { _, _ in poke() })
        observations.append(app.observe(\.isFinishedLaunching, options: [.new]) { _, _ in poke() })
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            notes.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if a?.processIdentifier == self?.app.processIdentifier { self?.enforce() }
            })
        }
        // Fallback for windows shown before the app reports itself as launched.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.enforce() }
        enforce()
    }

    private func enforce() {
        guard timer != nil, !app.isTerminated else { return }
        if !app.isHidden || app.isActive {
            surfaced += 1
            app.hide()
            onLog?("re-hid \(app.bundleIdentifier ?? "app") (\(surfaced))")
            onSurfaced?()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observations.forEach { $0.invalidate() }; observations.removeAll()
        notes.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; notes.removeAll()
    }

    deinit { stop() }
}

final class AppLauncher {
    private let fm = FileManager.default
    var isAppAvailable: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// Self-test hook: pretend nothing is installed.
    var simulateMissing: Set<TargetApp> = []

    func resolve(_ app: TargetApp) -> ResolvedApp? {
        if simulateMissing.contains(app) { return nil }
        if let path = UserDefaults.standard.string(forKey: app.defaultsKey) {
            let url = URL(fileURLWithPath: path)
            if isAppBundle(url) { return ResolvedApp(url: url, source: "手动选择") }
        }
        for id in app.observedBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               isAppBundle(url), bundleName(url)?.localizedCaseInsensitiveContains(app.displayName) == true {
                return ResolvedApp(url: url, source: "Bundle ID \(id)")
            }
        }
        let dirs = [URL(fileURLWithPath: "/Applications"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for d in dirs {
            let url = d.appendingPathComponent(app.bundleFileName)
            if isAppBundle(url) { return ResolvedApp(url: url, source: "按名称查找") }
        }
        return nil
    }

    func setOverride(_ url: URL?, for app: TargetApp) {
        if let url { UserDefaults.standard.set(url.path, forKey: app.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: app.defaultsKey) }
    }

    func hasOverride(_ app: TargetApp) -> Bool { UserDefaults.standard.string(forKey: app.defaultsKey) != nil }

    /// Self-test hooks: log opens / quits instead of performing them, and treat every target as not running.
    var dryRun = false
    var onAction: ((String) -> Void)?

    func launch(_ url: URL, completion: @escaping (Error?) -> Void) {
        if dryRun {
            onAction?("launch \(url.path) (dry run)")
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func isRunning(_ url: URL) -> Bool {
        if dryRun { return false }
        guard let id = Bundle(url: url)?.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Starts the app hidden and in the background so it is warm when the transformation ends.
    /// Only used when the app is not running yet, so the user's open windows are never hidden.
    func prelaunch(_ url: URL, completion: @escaping (NSRunningApplication?) -> Void) {
        if dryRun {
            onAction?("prelaunch \(url.path) hidden (dry run)")
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
            DispatchQueue.main.async { completion(app) }
        }
    }

    /// Politely quits an app this launcher started in the background for a run that was then cancelled.
    func quitPrelaunched(_ app: NSRunningApplication?) {
        if dryRun || app == nil { onAction?("quit prelaunched app\(dryRun ? " (dry run)" : "")"); return }
        onAction?("quit prelaunched \(app?.bundleIdentifier ?? "?")")
        app?.terminate()
    }

    /// Lets the user pick the .app when it cannot be located.
    func chooseApp(for app: TargetApp) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择 \(app.displayName).app"
        panel.message = "未能自动定位 \(app.displayName)，请选择对应的应用程序。"
        panel.prompt = "使用此 App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, isAppBundle(url) else { return nil }
        setOverride(url, for: app)
        return url
    }

    private func isAppBundle(_ url: URL) -> Bool {
        guard url.pathExtension == "app", isAppAvailable(url) else { return false }
        return Bundle(url: url)?.bundleIdentifier != nil
    }

    private func bundleName(_ url: URL) -> String? {
        let b = Bundle(url: url)
        return (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? b?.object(forInfoDictionaryKey: "CFBundleName")) as? String
    }
}
