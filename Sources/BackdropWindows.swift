import Foundation

/// One connection to an already-discovered, local app renderer.
@MainActor
protocol BackdropWindowClient: AnyObject {
    var isConnected: Bool { get }
    func connect(target: DebugTarget, port: Int) async throws
    func command(method: String, params: [String: Any]) async throws -> [String: Any]
    func disconnect()
}

extension CDPClient: BackdropWindowClient { }

enum BackdropWindowsError: LocalizedError {
    case noWindows
    case disconnected
    case invalidResult
    case windowFailures(Int, String)

    var errorDescription: String? {
        switch self {
        case .noWindows:
            return "No supported ChatGPT chat windows found. Embedded browser and utility windows are excluded."
        case .disconnected:
            return "Connect to ChatGPT before applying a background."
        case .invalidResult:
            return "This ChatGPT window did not confirm that its background was applied."
        case .windowFailures(let count, let detail):
            return "Could not update \(count) ChatGPT window\(count == 1 ? "" : "s"). Other available windows were still processed. \(detail)"
        }
    }
}

/// Tracks the app's existing and newly opened primary chat renderers.
/// The model serializes public mutation calls, including its discovery timer.
@MainActor
final class BackdropWindows {
    private final class Window {
        var target: DebugTarget
        let client: BackdropWindowClient
        var scriptIdentifier: String?
        var lastAppliedRevision = 0
        var visibleRevision = 0
        var hasVisibleTheme = false
        var uncertain = false

        init(target: DebugTarget, client: BackdropWindowClient) {
            self.target = target
            self.client = client
        }
    }

    private let discover: @MainActor (Int) async throws -> [DebugTarget]
    private let makeClient: @MainActor () -> BackdropWindowClient
    private var windows: [String: Window] = [:]
    private var port: Int?
    private var desiredSource: String?
    private var revision = 0
    private var discardedUncertainty = false

    var isConnected: Bool { windows.values.contains { $0.client.isConnected } }
    var hasDesiredTheme: Bool { desiredSource != nil }
    var cleanupUncertain: Bool {
        discardedUncertainty || windows.values.contains { $0.uncertain }
    }
    var appliedWindowCount: Int {
        guard desiredSource != nil else { return 0 }
        return windows.values.filter {
            $0.client.isConnected && $0.hasVisibleTheme && $0.visibleRevision == revision
        }.count
    }

    init(
        discover: @escaping @MainActor (Int) async throws -> [DebugTarget] = { port in
            try await CDPClient.discover(port: port)
        },
        makeClient: @escaping @MainActor () -> BackdropWindowClient = { CDPClient() }
    ) {
        self.discover = discover
        self.makeClient = makeClient
    }

    static func isShell(_ target: DebugTarget) -> Bool {
        guard target.type == "page", let url = URLComponents(string: target.url) else { return false }
        guard url.scheme == "app", url.host == "-", url.path == "/index.html",
              url.port == nil, url.user == nil, url.password == nil else { return false }
        let routes = (url.queryItems ?? []).filter { $0.name == "initialRoute" }
        guard routes.count <= 1 else { return false }
        let route = routes.first?.value ?? ""
        let path = String(route.prefix { $0 != "?" && $0 != "#" })
        let utilityPrefixes = ["/avatar-overlay", "/global-dictation", "/spotlight", "/hotkey-window"]
        return !utilityPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Used for both application and restoration. It deliberately excludes the
    /// separate detached browser shell and all third-party or iframe documents.
    static let documentGuard = #"""
    if (self !== top) return {active: false, unsupported: true};
    const backdropDocumentURL = new URL(location.href);
    if (backdropDocumentURL.protocol !== 'app:' || backdropDocumentURL.hostname !== '-' ||
        backdropDocumentURL.port !== '' || backdropDocumentURL.username !== '' ||
        backdropDocumentURL.password !== '' || backdropDocumentURL.pathname !== '/index.html') {
      return {active: false, unsupported: true};
    }
    const backdropInitialRoutes = backdropDocumentURL.searchParams.getAll('initialRoute');
    if (backdropInitialRoutes.length > 1) return {active: false, unsupported: true};
    const backdropRoutePath = (backdropInitialRoutes[0] ?? '').split(/[?#]/, 1)[0];
    if (['/avatar-overlay', '/global-dictation', '/spotlight', '/hotkey-window'].some(
        prefix => backdropRoutePath === prefix || backdropRoutePath.startsWith(prefix + '/'))) {
      return {active: false, unsupported: true};
    }
    """#

    /// Connects every primary chat window, without applying a theme yet.
    func connect(port: Int) async throws {
        guard (1024...65535).contains(port) else { throw CDPError.invalidPort }
        if let previous = self.port, previous != port {
            await restore()
            disconnect()
        }
        self.port = port
        let failures = try await reconcileWindows()
        guard isConnected else {
            if let failure = failures.first { throw failure }
            throw BackdropWindowsError.noWindows
        }
    }

    /// Discovers new windows and applies only the current revision they lack.
    /// An unchanged discovery pass does not re-evaluate scripts or restart GIFs.
    func reconcile() async throws {
        guard port != nil else { throw BackdropWindowsError.disconnected }
        let failures = try await reconcileWindows()
        if !failures.isEmpty { throw summarized(failures) }
    }

    func apply(source: String) async throws {
        guard port != nil else { throw BackdropWindowsError.disconnected }
        if desiredSource != source {
            desiredSource = source
            revision += 1
        }
        // Reconciliation also visits connected windows and updates a stale revision.
        let failures = try await reconcileWindows()
        guard !windows.isEmpty else { throw BackdropWindowsError.noWindows }
        if !failures.isEmpty { throw summarized(failures) }
        guard appliedWindowCount > 0 else { throw BackdropWindowsError.noWindows }
    }

    /// Keep edits made while all chat windows are closed for the next window.
    /// This stages an already-enabled theme only; Restore remains authoritative.
    func updateDesiredSource(source: String) {
        guard desiredSource != nil, desiredSource != source else { return }
        desiredSource = source
        revision += 1
    }

    /// Stop inheritance first, then attempt both cleanup operations in every window.
    /// Failures in one window never prevent cleanup of the remaining windows.
    func restore() async {
        desiredSource = nil
        for id in windows.keys.sorted() {
            guard let window = windows[id] else { continue }
            if !window.client.isConnected {
                do {
                    guard let port = port else { throw CDPError.disconnected }
                    _ = try CDPClient.validatedWebSocketURL(target: window.target, port: port)
                    forgetSessionRegistration(window)
                    try await window.client.connect(target: window.target, port: port)
                    window.uncertain = false
                } catch {
                    if window.scriptIdentifier != nil || window.hasVisibleTheme || window.uncertain {
                        window.uncertain = true
                    }
                    continue
                }
            }
            await cleanup(window, restoreVisibleTheme: true)
        }
    }

    /// Call restore() before disconnect() when the renderer is still alive.
    func disconnect() {
        if windows.values.contains(where: {
            $0.scriptIdentifier != nil || $0.hasVisibleTheme || $0.uncertain
        }) {
            discardedUncertainty = true
        }
        for window in windows.values { window.client.disconnect() }
        windows.removeAll()
        desiredSource = nil
        port = nil
    }

    /// The caller may use this only after the old ChatGPT processes were
    /// confirmed terminated. No remote styles or registrations can survive them.
    func resetAfterAppRestart() {
        for window in windows.values { window.client.disconnect() }
        windows.removeAll()
        desiredSource = nil
        port = nil
        revision = 0
        discardedUncertainty = false
    }

    private func reconcileWindows() async throws -> [Error] {
        guard let port = port else { throw BackdropWindowsError.disconnected }
        let advertised = try await discover(port)
        let eligible = advertised.filter(Self.isShell)
        let eligibleIDs = Set(eligible.map(\.id))
        let advertisedIDs = Set(advertised.map(\.id))
        var failures: [Error] = []

        for id in windows.keys.sorted() where !eligibleIDs.contains(id) {
            guard let window = windows.removeValue(forKey: id) else { continue }
            if advertisedIDs.contains(id) {
                // The same target navigated away. Remove only our registered script;
                // never evaluate JavaScript in the now-unsupported document.
                await cleanup(window, restoreVisibleTheme: false)
                if window.scriptIdentifier != nil || window.uncertain {
                    discardedUncertainty = true
                }
            }
            // A target missing from discovery was destroyed, taking its scripts with it.
            window.client.disconnect()
        }

        var visited = Set<String>()
        for target in eligible.sorted(by: { $0.id < $1.id }) {
            guard visited.insert(target.id).inserted else { continue }
            do {
                _ = try CDPClient.validatedWebSocketURL(target: target, port: port)
                let window: Window
                if let existing = windows[target.id] {
                    window = existing
                    window.target = target
                } else {
                    window = Window(target: target, client: makeClient())
                    windows[target.id] = window
                }
                if !window.client.isConnected {
                    // Page registrations belong to the CDP session. A new socket
                    // cannot remove or rely on identifiers from the old session.
                    forgetSessionRegistration(window)
                    try await window.client.connect(target: target, port: port)
                    window.uncertain = false
                }
                if let source = desiredSource, window.lastAppliedRevision != revision {
                    try await install(source: source, in: window)
                }
            } catch { failures.append(error) }
        }
        return failures
    }

    private func install(source: String, in window: Window) async throws {
        let result = try await window.client.command(method: "Runtime.evaluate", params: [
            "expression": source, "returnByValue": true, "awaitPromise": true,
            "allowUnsafeEvalBlockedByCSP": false
        ])
        guard let remote = result["result"] as? [String: Any],
              let value = remote["value"] as? [String: Any],
              value["active"] as? Bool == true else { throw BackdropWindowsError.invalidResult }
        window.hasVisibleTheme = true
        window.visibleRevision = revision

        if let identifier = window.scriptIdentifier {
            _ = try await window.client.command(method: "Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": identifier])
            window.scriptIdentifier = nil
        }
        do {
            let registration = try await window.client.command(method: "Page.addScriptToEvaluateOnNewDocument", params: ["source": source])
            guard let identifier = registration["identifier"] as? String else { throw CDPError.malformedResponse }
            window.scriptIdentifier = identifier
        } catch {
            // A command may execute before its reply is lost. Its unknown identifier
            // cannot be proven removed later, even if visible styles were restored.
            window.uncertain = true
            throw error
        }
        window.lastAppliedRevision = revision
    }

    private func cleanup(_ window: Window, restoreVisibleTheme: Bool) async {
        if let identifier = window.scriptIdentifier {
            do {
                _ = try await window.client.command(method: "Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": identifier])
                window.scriptIdentifier = nil
            } catch { window.uncertain = true }
        }
        if restoreVisibleTheme {
            do {
                let result = try await window.client.command(method: "Runtime.evaluate", params: [
                    "expression": "(() => {\n\(Self.documentGuard)\nreturn globalThis.__chatGPTBackdrop?.restore();\n})()", "returnByValue": true,
                    "allowUnsafeEvalBlockedByCSP": false
                ])
                let remote = result["result"] as? [String: Any]
                let value = remote?["value"] as? [String: Any]
                if value?["unsupported"] as? Bool == true {
                    window.uncertain = true
                } else {
                    window.hasVisibleTheme = false
                    window.visibleRevision = 0
                    window.lastAppliedRevision = 0
                }
            } catch { window.uncertain = true }
        }
    }

    private func forgetSessionRegistration(_ window: Window) {
        window.scriptIdentifier = nil
        window.lastAppliedRevision = 0
    }

    private func summarized(_ failures: [Error]) -> Error {
        BackdropWindowsError.windowFailures(failures.count,
            String((failures.first?.localizedDescription ?? "Local connection failed.").prefix(300)))
    }
}
