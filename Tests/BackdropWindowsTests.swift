import Foundation

// Visible DOM styling belongs to a renderer, while Page document registrations
// belong to the CDP session that created them. A replacement socket therefore
// needs a new registration even if the renderer's existing DOM is unchanged.
@MainActor
private final class FakeRenderer {
    var active = false
    var scripts: [String: String] = [:]
}

private struct FakeCall {
    let targetID: String
    let method: String
    let params: [String: Any]
}

private struct FailurePlan {
    let targetID: String
    let method: String
    var restoreOnly = false
    var afterExecution = false
}

@MainActor
private final class FakeWorld {
    var targets: [DebugTarget] = []
    var clients: [FakeClient] = []
    var renderers: [String: FakeRenderer] = [:]
    var calls: [FakeCall] = []
    var failures: [FailurePlan] = []
    var failedConnections: Set<String> = []
    var discoveryFailure = false
    var discoveryCalls = 0
    var unsupportedRestoreTargets: Set<String> = []
    var nextScript = 0

    func manager() -> BackdropWindows {
        BackdropWindows(discover: { [unowned self] _ in
            self.discoveryCalls += 1
            if self.discoveryFailure { throw CDPError.timedOut }
            return self.targets
        }, makeClient: { [unowned self] in
            let client = FakeClient(world: self)
            self.clients.append(client)
            return client
        })
    }

    func renderer(_ id: String) -> FakeRenderer {
        if let existing = renderers[id] { return existing }
        let created = FakeRenderer()
        renderers[id] = created
        return created
    }

    func count(_ method: String, for id: String? = nil) -> Int {
        calls.filter { $0.method == method && (id == nil || $0.targetID == id) }.count
    }

    func transportDrop(_ id: String) {
        for client in clients where client.targetID == id { client.dropTransport() }
    }

    func close(_ id: String) {
        targets.removeAll { $0.id == id }
        transportDrop(id)
        renderer(id).active = false
    }

    func restartApp() {
        for client in clients { client.dropTransport() }
        for renderer in renderers.values { renderer.active = false; renderer.scripts.removeAll() }
        targets.removeAll()
    }

    func takeFailure(targetID: String, method: String, expression: String) -> FailurePlan? {
        guard let index = failures.firstIndex(where: {
            $0.targetID == targetID && $0.method == method &&
                (!$0.restoreOnly || expression.contains("restore()"))
        }) else { return nil }
        return failures.remove(at: index)
    }
}

@MainActor
private final class FakeClient: BackdropWindowClient {
    unowned let world: FakeWorld
    var isConnected = false
    var targetID = ""
    private var ownedScriptIDs: Set<String> = []

    init(world: FakeWorld) { self.world = world }

    func connect(target: DebugTarget, port: Int) async throws {
        // CDPClient.connect replaces the old WebSocket with a fresh session.
        dropTransport()
        targetID = target.id
        world.calls.append(FakeCall(targetID: targetID, method: "connect", params: ["port": port]))
        if world.failedConnections.contains(targetID) { throw CDPError.disconnected }
        _ = world.renderer(targetID)
        isConnected = true
    }

    func command(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard isConnected else { throw CDPError.disconnected }
        world.calls.append(FakeCall(targetID: targetID, method: method, params: params))
        let expression = params["expression"] as? String ?? ""
        let failure = world.takeFailure(targetID: targetID, method: method, expression: expression)
        if let failure, !failure.afterExecution { throw CDPError.timedOut }
        let remote = world.renderer(targetID)
        let result: [String: Any]
        switch method {
        case "Runtime.evaluate":
            if expression.contains("restore()") {
                if world.unsupportedRestoreTargets.contains(targetID) {
                    result = ["result": ["value": ["active": false, "unsupported": true]]]
                } else {
                    remote.active = false
                    result = ["result": ["value": ["active": false, "restored": true]]]
                }
            } else {
                remote.active = true
                result = ["result": ["value": ["active": true]]]
            }
        case "Page.addScriptToEvaluateOnNewDocument":
            world.nextScript += 1
            let identifier = "\(targetID)-script-\(world.nextScript)"
            remote.scripts[identifier] = params["source"] as? String ?? ""
            ownedScriptIDs.insert(identifier)
            result = ["identifier": identifier]
        case "Page.removeScriptToEvaluateOnNewDocument":
            guard let identifier = params["identifier"] as? String,
                  ownedScriptIDs.remove(identifier) != nil else {
                throw CDPError.protocolFailure(code: -32000, message: "Script not found in this CDP session.")
            }
            remote.scripts.removeValue(forKey: identifier)
            result = [:]
        default:
            result = [:]
        }
        if let failure, failure.afterExecution { throw CDPError.timedOut }
        return result
    }

    func disconnect() {
        world.calls.append(FakeCall(targetID: targetID, method: "disconnect", params: [:]))
        dropTransport()
    }

    func dropTransport() {
        isConnected = false
        if let remote = world.renderers[targetID] {
            for identifier in ownedScriptIDs { remote.scripts.removeValue(forKey: identifier) }
        }
        ownedScriptIDs.removeAll()
        // Do not clear remote.active: existing DOM styling outlives the socket.
    }
}

@MainActor
private final class Suite {
    var checks: [[String: Any]] = []

    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        let passed = condition()
        checks.append(["name": name, "pass": passed])
        print("\(passed ? "PASS" : "FAIL") \(name)")
    }

    func scenario(_ name: String, _ body: () async throws -> Void) async {
        do { try await body() }
        catch {
            checks.append(["name": "\(name): unexpected error", "pass": false,
                           "error": error.localizedDescription])
            print("FAIL \(name): \(error.localizedDescription)")
        }
    }

    func throwsError(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); check(name, false) }
        catch { check(name, true) }
    }
}

@main
@MainActor
struct BackdropWindowsTests {
    private static let port = 54321
    private static let firstSource = "/* wallpaper revision one */ (() => ({active: true}))()"
    private static let secondSource = "/* wallpaper revision two */ (() => ({active: true}))()"

    private static func target(_ id: String, url: String = "app://-/index.html",
                               type: String = "page", endpoint: String? = nil) -> DebugTarget {
        DebugTarget(id: id, type: type, title: "Test-only app shell", url: url,
                    webSocketDebuggerUrl: endpoint ?? "ws://127.0.0.1:\(port)/devtools/page/\(id)")
    }

    static func main() async {
        let suite = Suite()

        await suite.scenario("new conversation window") {
            let world = FakeWorld()
            world.targets = [target("main")]
            let windows = world.manager()
            try await windows.connect(port: port)
            suite.check("connect accepts a main app shell", windows.isConnected)
            suite.check("connect does not apply a theme before Apply", !windows.hasDesiredTheme && windows.appliedWindowCount == 0)
            suite.check("connect sends no styling or document registration", world.count("Runtime.evaluate") == 0 && world.count("Page.addScriptToEvaluateOnNewDocument") == 0)

            try await windows.apply(source: firstSource)
            suite.check("Apply styles the first window", world.renderer("main").active && windows.appliedWindowCount == 1)
            suite.check("Apply registers one document script", world.renderer("main").scripts.count == 1)
            suite.check("Apply retains the desired theme", windows.hasDesiredTheme)
            let mainEvaluations = world.count("Runtime.evaluate", for: "main")
            let mainRegistrations = world.count("Page.addScriptToEvaluateOnNewDocument", for: "main")
            for _ in 0..<3 { try await windows.reconcile() }
            suite.check("unchanged polling does not reevaluate or restart a GIF", world.count("Runtime.evaluate", for: "main") == mainEvaluations)
            suite.check("unchanged polling does not register duplicate document scripts", world.count("Page.addScriptToEvaluateOnNewDocument", for: "main") == mainRegistrations)

            world.targets.append(target("conversation", url: "app://-/index.html?initialRoute=%2Fthread%2Ftest-only"))
            try await windows.reconcile()
            suite.check("a conversation opened later receives the current background", world.renderer("conversation").active && windows.appliedWindowCount == 2)
            suite.check("the new conversation registers one persistent script", world.renderer("conversation").scripts.count == 1)
            suite.check("opening a conversation does not reevaluate the main window", world.count("Runtime.evaluate", for: "main") == mainEvaluations)

            try await windows.apply(source: secondSource)
            suite.check("a setting change updates both existing windows", world.count("Runtime.evaluate", for: "main") == mainEvaluations + 1 && world.count("Runtime.evaluate", for: "conversation") == 2)
            suite.check("settings updates replace rather than accumulate registrations", world.renderer("main").scripts.count == 1 && world.renderer("conversation").scripts.count == 1)
            suite.check("both registrations contain the latest settings", Set(world.renderer("main").scripts.values) == [secondSource] && Set(world.renderer("conversation").scripts.values) == [secondSource])

            let retainedEvaluations = world.count("Runtime.evaluate", for: "conversation")
            world.close("main")
            try await windows.reconcile()
            suite.check("closing the main window retains a conversation connection", windows.isConnected && windows.appliedWindowCount == 1)
            suite.check("closing the main window does not reset the remaining conversation", world.renderer("conversation").active && world.count("Runtime.evaluate", for: "conversation") == retainedEvaluations)
            world.targets.append(target("third", url: "app://-/index.html?initialRoute=%2Fthread%2Fanother-test"))
            try await windows.reconcile()
            suite.check("new windows are still followed after the main window closes", world.renderer("third").active && windows.appliedWindowCount == 2)

            await windows.restore()
            suite.check("Restore removes visible styling from every surviving window", !world.renderer("conversation").active && !world.renderer("third").active)
            suite.check("Restore removes every known document registration", world.renderer("conversation").scripts.isEmpty && world.renderer("third").scripts.isEmpty)
            suite.check("Restore clears the desired theme and applied count", !windows.hasDesiredTheme && windows.appliedWindowCount == 0)
            suite.check("a successful restore has no cleanup uncertainty", !windows.cleanupUncertain)
            world.targets.append(target("after-restore"))
            try await windows.reconcile()
            suite.check("new windows after Restore are not automatically restyled", !world.renderer("after-restore").active && world.renderer("after-restore").scripts.isEmpty && world.count("Runtime.evaluate", for: "after-restore") == 0)
            windows.disconnect()
            suite.check("disconnect after Restore closes all client connections", !windows.isConnected && world.clients.allSatisfy { !$0.isConnected })
        }

        await suite.scenario("two windows already open") {
            let world = FakeWorld()
            world.targets = [target("one"), target("two", url: "app://-/index.html?initialRoute=%2Fthread%2Ftwo")]
            let windows = world.manager()
            try await windows.connect(port: port)
            suite.check("two existing index shells are accepted without an ambiguity error", windows.isConnected)
            suite.check("two connected windows still await explicit Apply", world.count("Runtime.evaluate") == 0 && !windows.hasDesiredTheme)
            try await windows.apply(source: firstSource)
            suite.check("Apply reaches both windows that were already open", world.renderer("one").active && world.renderer("two").active && windows.appliedWindowCount == 2)
            await windows.restore()
            windows.disconnect()
            suite.check("quit-style restoration clears both visible themes and registrations", !world.renderer("one").active && !world.renderer("two").active && world.renderer("one").scripts.isEmpty && world.renderer("two").scripts.isEmpty)
            suite.check("quit-style restoration closes every client", world.clients.allSatisfy { !$0.isConnected } && !windows.cleanupUncertain)
        }

        await suite.scenario("settings change while every chat window is closed") {
            let world = FakeWorld()
            world.targets = [target("closed-main")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            world.close("closed-main")
            try await windows.reconcile()
            suite.check("closing every chat window retains the enabled theme intent", !windows.isConnected && windows.appliedWindowCount == 0 && windows.hasDesiredTheme)
            let callsBeforeStage = world.calls.count
            let discoveriesBeforeStage = world.discoveryCalls
            windows.updateDesiredSource(source: secondSource)
            suite.check("staging settings with no windows does not discover or connect", world.calls.count == callsBeforeStage && world.discoveryCalls == discoveriesBeforeStage)
            world.targets = [target("reopened-chat", url: "app://-/index.html?initialRoute=/thread/reopened")]
            try await windows.reconcile()
            suite.check("a reopened chat inherits the settings staged while no windows existed", world.renderer("reopened-chat").active && Set(world.renderer("reopened-chat").scripts.values) == [secondSource])
            let latestApply = world.calls.last { $0.targetID == "reopened-chat" && $0.method == "Runtime.evaluate" }
            suite.check("a reopened chat evaluates the new source rather than stale settings", latestApply?.params["expression"] as? String == secondSource)
            let evaluations = world.count("Runtime.evaluate", for: "reopened-chat")
            let registrations = world.count("Page.addScriptToEvaluateOnNewDocument", for: "reopened-chat")
            windows.updateDesiredSource(source: secondSource)
            try await windows.reconcile()
            suite.check("staging the unchanged source does not reset an already applied window", world.count("Runtime.evaluate", for: "reopened-chat") == evaluations && world.count("Page.addScriptToEvaluateOnNewDocument", for: "reopened-chat") == registrations)
            await windows.restore()
            let callsAfterRestore = world.calls.count
            let discoveriesAfterRestore = world.discoveryCalls
            windows.updateDesiredSource(source: "/* settings edited after Restore */ (() => ({active:true}))()")
            suite.check("staging settings after Restore does not re-enable or attach a theme", !windows.hasDesiredTheme && world.calls.count == callsAfterRestore && world.discoveryCalls == discoveriesAfterRestore)
            world.close("reopened-chat")
            world.targets = [target("after-restored-stage")]
            try await windows.reconcile()
            suite.check("a new window after Restore and a settings edit remains unthemed", !world.renderer("after-restored-stage").active && world.renderer("after-restored-stage").scripts.isEmpty && world.count("Runtime.evaluate", for: "after-restored-stage") == 0)
            windows.disconnect()
        }

        await suite.scenario("same target reconnect") {
            let world = FakeWorld()
            world.targets = [target("reconnected")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            let evaluations = world.count("Runtime.evaluate")
            let registrations = world.renderer("reconnected").scripts
            let registrationCalls = world.count("Page.addScriptToEvaluateOnNewDocument")
            let removalCalls = world.count("Page.removeScriptToEvaluateOnNewDocument")
            world.transportDrop("reconnected")
            suite.check("dropping a session removes its scripts while retaining the visible theme", world.renderer("reconnected").scripts.isEmpty && world.renderer("reconnected").active)
            try await windows.reconcile()
            suite.check("the same renderer reconnects and receives a fresh session registration", windows.isConnected && world.renderer("reconnected").scripts.count == 1 && Set(world.renderer("reconnected").scripts.keys).isDisjoint(with: registrations.keys))
            suite.check("a replacement session reevaluates the idempotent source and registers once", world.count("Runtime.evaluate") == evaluations + 1 && world.count("Page.addScriptToEvaluateOnNewDocument") == registrationCalls + 1)
            suite.check("reconnect never removes a script id owned by the old session", world.count("Page.removeScriptToEvaluateOnNewDocument") == removalCalls)
            let reconnectedEvaluations = world.count("Runtime.evaluate")
            try await windows.reconcile()
            suite.check("unchanged polling after reconnect does not reevaluate again", world.count("Runtime.evaluate") == reconnectedEvaluations)
            await windows.restore()
            suite.check("restoration after reconnect removes the fresh registration and visible theme", world.renderer("reconnected").scripts.isEmpty && !world.renderer("reconnected").active && !windows.cleanupUncertain)
            windows.disconnect()
        }

        await suite.scenario("restore after a dropped session") {
            let world = FakeWorld()
            world.targets = [target("restore-reconnect")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            let registrations = world.count("Page.addScriptToEvaluateOnNewDocument")
            let removals = world.count("Page.removeScriptToEvaluateOnNewDocument")
            world.transportDrop("restore-reconnect")
            await windows.restore()
            suite.check("Restore reconnects to clear visible DOM styling left by the old session", !world.renderer("restore-reconnect").active && world.renderer("restore-reconnect").scripts.isEmpty)
            suite.check("Restore on a new session does not use stale script ids or create new scripts", world.count("Page.removeScriptToEvaluateOnNewDocument") == removals && world.count("Page.addScriptToEvaluateOnNewDocument") == registrations)
            suite.check("successful restoration after session loss has no cleanup uncertainty", !windows.hasDesiredTheme && !windows.cleanupUncertain)
            windows.disconnect()
        }

        await suite.scenario("temporary discovery failure") {
            let world = FakeWorld()
            world.targets = [target("surviving")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            let evaluations = world.count("Runtime.evaluate")
            let registrations = world.renderer("surviving").scripts
            world.discoveryFailure = true
            await suite.throwsError("a temporary discovery timeout is surfaced") { try await windows.reconcile() }
            suite.check("failed discovery does not discard a healthy renderer or theme", windows.isConnected && windows.hasDesiredTheme && world.renderer("surviving").active)
            suite.check("failed discovery does not reset media or registrations", world.count("Runtime.evaluate") == evaluations && world.renderer("surviving").scripts == registrations)
            world.discoveryFailure = false
            try await windows.reconcile()
            suite.check("recovery from discovery timeout does not reevaluate an unchanged theme", world.count("Runtime.evaluate") == evaluations && windows.appliedWindowCount == 1)
            await windows.restore()
            windows.disconnect()
        }

        await suite.scenario("same target navigates outside the app shell") {
            let world = FakeWorld()
            world.targets = [target("navigating"), target("staying")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            let previousEvaluations = world.count("Runtime.evaluate", for: "navigating")
            let stayingEvaluations = world.count("Runtime.evaluate", for: "staying")
            // A new document replaces the old DOM but retains Page registrations.
            world.renderer("navigating").active = false
            world.targets = [target("navigating", url: "https://example.test/"), target("staying")]
            try await windows.reconcile()
            suite.check("navigation away removes the old registration without evaluating the new page", world.renderer("navigating").scripts.isEmpty && world.count("Runtime.evaluate", for: "navigating") == previousEvaluations)
            suite.check("navigation away leaves other app windows connected and unchanged", windows.isConnected && windows.appliedWindowCount == 1 && world.count("Runtime.evaluate", for: "staying") == stayingEvaluations)
            await windows.restore()
            windows.disconnect()
        }

        await suite.scenario("navigation races Restore before discovery") {
            let world = FakeWorld()
            world.targets = [target("restore-race")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            // This transport fake does not execute JavaScript. Simulate the
            // guard's unsupported result and verify the manager sends that guard
            // and handles its result instead of calling an unguarded API.
            world.targets = [target("restore-race", url: "https://example.test/")]
            world.renderer("restore-race").active = false
            world.unsupportedRestoreTargets.insert("restore-race")
            await windows.restore()
            let cleanupCall = world.calls.last { $0.method == "Runtime.evaluate" }
            let expression = cleanupCall?.params["expression"] as? String ?? ""
            suite.check("Restore sends the document-origin guard when navigation races discovery", expression.contains(BackdropWindows.documentGuard) && expression.contains("restore()"))
            suite.check("an unsupported restoration result is surfaced without restarting inheritance", windows.cleanupUncertain && !windows.hasDesiredTheme)
            suite.check("a race still removes the known registration from its existing CDP session", world.renderer("restore-race").scripts.isEmpty)
            windows.disconnect()
        }

        await suite.scenario("restore failure isolation") {
            let world = FakeWorld()
            world.targets = [target("unresponsive"), target("healthy")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            world.failures = [FailurePlan(targetID: "unresponsive", method: "Runtime.evaluate", restoreOnly: true)]
            await windows.restore()
            suite.check("one failed restoration does not prevent another window being restored", !world.renderer("healthy").active && world.renderer("healthy").scripts.isEmpty)
            suite.check("restoration failure is reported as cleanup uncertainty", windows.cleanupUncertain)
            suite.check("a failed restore still stops automatic theme application", !windows.hasDesiredTheme)
            world.targets.append(target("later"))
            try await windows.reconcile()
            suite.check("windows opened after a partial restore do not receive a new theme", world.count("Runtime.evaluate", for: "later") == 0 && world.renderer("later").scripts.isEmpty)
            windows.disconnect()
        }

        await suite.scenario("apply failure isolation and retry") {
            let world = FakeWorld()
            world.targets = [target("not-ready"), target("ready")]
            let windows = world.manager()
            try await windows.connect(port: port)
            world.failures = [FailurePlan(targetID: "not-ready", method: "Runtime.evaluate")]
            await suite.throwsError("Apply reports a partial application failure") {
                try await windows.apply(source: firstSource)
            }
            suite.check("a failing window does not block styling a healthy window", world.renderer("ready").active)
            suite.check("partial application retains the desired theme for retry", windows.hasDesiredTheme)
            let readyEvaluations = world.count("Runtime.evaluate", for: "ready")
            try await windows.reconcile()
            suite.check("reconciliation retries the window that was not ready", world.renderer("not-ready").active && windows.appliedWindowCount == 2)
            suite.check("a partial retry does not reevaluate successful windows", world.count("Runtime.evaluate", for: "ready") == readyEvaluations)
            suite.check("a recovered application has one registration per window", world.renderer("not-ready").scripts.count == 1 && world.renderer("ready").scripts.count == 1)
            await windows.restore()
            windows.disconnect()
        }

        await suite.scenario("document-script removal failure") {
            let world = FakeWorld()
            world.targets = [target("failed-removal"), target("healthy-removal")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            world.failures = [FailurePlan(targetID: "failed-removal", method: "Page.removeScriptToEvaluateOnNewDocument")]
            await windows.restore()
            suite.check("failed registration removal still restores that window's visible appearance", !world.renderer("failed-removal").active)
            suite.check("failed removal does not prevent another window's complete cleanup", !world.renderer("healthy-removal").active && world.renderer("healthy-removal").scripts.isEmpty)
            suite.check("an unremoved registration remains a reported cleanup uncertainty", windows.cleanupUncertain && !world.renderer("failed-removal").scripts.isEmpty && !windows.hasDesiredTheme)
            windows.disconnect()
        }

        await suite.scenario("uncertain registration") {
            let world = FakeWorld()
            world.targets = [target("lost-reply")]
            let windows = world.manager()
            try await windows.connect(port: port)
            world.failures = [FailurePlan(targetID: "lost-reply", method: "Page.addScriptToEvaluateOnNewDocument", afterExecution: true)]
            await suite.throwsError("an executed script registration with a lost reply reports failure") {
                try await windows.apply(source: firstSource)
            }
            suite.check("an unacknowledged registration marks cleanup as uncertain", windows.cleanupUncertain)
            suite.check("a lost registration reply still counts a visibly themed window", world.renderer("lost-reply").active && windows.appliedWindowCount == 1)
            await windows.restore()
            suite.check("visible restoration cannot erase uncertainty about an unknown script id", windows.cleanupUncertain && !windows.hasDesiredTheme)
            windows.disconnect()
        }

        await suite.scenario("disconnect without restoration") {
            let world = FakeWorld()
            world.targets = [target("interrupted")]
            let windows = world.manager()
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            windows.disconnect()
            suite.check("disconnect releases session registrations but leaves visible DOM styling", !windows.isConnected && world.renderer("interrupted").scripts.isEmpty && world.renderer("interrupted").active)
            suite.check("disconnect with an active theme reports cleanup uncertainty", windows.cleanupUncertain)
        }

        await suite.scenario("known application restart") {
            let world = FakeWorld()
            world.targets = [target("old-process")]
            let windows = world.manager()
            try await windows.connect(port: port)
            world.failures = [FailurePlan(targetID: "old-process", method: "Page.addScriptToEvaluateOnNewDocument", afterExecution: true)]
            await suite.throwsError("lost old-process registration starts with uncertain cleanup") {
                try await windows.apply(source: firstSource)
            }
            suite.check("old-process cleanup uncertainty is recorded before restart", windows.cleanupUncertain)
            world.restartApp()
            windows.resetAfterAppRestart()
            suite.check("a known app restart clears uncertainty from the terminated process", !windows.cleanupUncertain && !windows.isConnected && !windows.hasDesiredTheme)
            world.targets = [target("new-process")]
            try await windows.connect(port: port)
            try await windows.apply(source: firstSource)
            suite.check("a new process can connect and apply with clean bookkeeping", windows.appliedWindowCount == 1 && !windows.cleanupUncertain && world.renderer("new-process").scripts.count == 1)
            await windows.restore()
            windows.disconnect()
        }

        await suite.scenario("target and endpoint restrictions") {
            suite.check("different app index route queries are valid conversation windows", BackdropWindows.isShell(target("valid", url: "app://-/index.html?initialRoute=%2Fthread%2Ftest")))
            for route in ["/avatar-overlay", "/global-dictation", "/spotlight", "/hotkey-window"] {
                let encoded = route.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
                suite.check("utility initialRoute \(route) is excluded", !BackdropWindows.isShell(target("utility", url: "app://-/index.html?initialRoute=\(encoded)")))
                suite.check("utility initialRoute \(route) subpaths are excluded", !BackdropWindows.isShell(target("utility-child", url: "app://-/index.html?initialRoute=\(encoded)/child")))
            }
            suite.check("duplicate initialRoute values are excluded rather than choosing an ambiguous window route", !BackdropWindows.isShell(target("ambiguous", url: "app://-/index.html?initialRoute=/thread/test&initialRoute=/avatar-overlay")))
            let invalidRenderers = [
                target("browser", url: "app://-/detached-window.html"),
                target("external", url: "https://chatgpt.com/"),
                target("files", url: "app://fs/index.html"),
                target("wrong-path", url: "app://-/login.html"),
                target("credentials", url: "app://someone@-/index.html"),
                target("shell-port", url: "app://-:1234/index.html"),
                target("worker", type: "service_worker")
            ]
            for item in invalidRenderers {
                suite.check("renderer scope rejects \(item.id)", !BackdropWindows.isShell(item))
                let world = FakeWorld(); world.targets = [item]; let windows = world.manager()
                await suite.throwsError("Connect rejects \(item.id) without a shell") { try await windows.connect(port: port) }
                suite.check("\(item.id) never receives a client connection or styling", world.count("connect") == 0 && world.count("Runtime.evaluate") == 0)
                windows.disconnect()
            }
            let invalidEndpoints = [
                target("remote-socket", endpoint: "ws://remote.example:\(port)/devtools/page/test"),
                target("wrong-socket-port", endpoint: "ws://127.0.0.1:\(port + 1)/devtools/page/test"),
                target("socket-credentials", endpoint: "ws://user:pass@127.0.0.1:\(port)/devtools/page/test")
            ]
            for item in invalidEndpoints {
                let world = FakeWorld(); world.targets = [item]; let windows = world.manager()
                await suite.throwsError("Connect rejects \(item.id)") { try await windows.connect(port: port) }
                suite.check("\(item.id) never reaches a fake connection", world.count("connect") == 0)
                windows.disconnect()
            }
            for invalidPort in [80, 65536] {
                let world = FakeWorld(); world.targets = [target("invalid-port")]; let windows = world.manager()
                await suite.throwsError("Connect rejects invalid local port \(invalidPort)") { try await windows.connect(port: invalidPort) }
                suite.check("invalid port \(invalidPort) never reaches a client", world.count("connect") == 0)
                windows.disconnect()
            }
        }

        let passed = suite.checks.filter { ($0["pass"] as? Bool) == true }.count
        let report: [String: Any] = ["passed": passed, "total": suite.checks.count,
                                   "success": passed == suite.checks.count, "checks": suite.checks]
        if let argument = CommandLine.arguments.firstIndex(of: "--report"),
           argument + 1 < CommandLine.arguments.count {
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[argument + 1]), options: .atomic)
            } catch {
                fputs("Could not save the test report: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        print("\(passed)/\(suite.checks.count) offline multiwindow checks passed.")
        exit(passed == suite.checks.count ? 0 : 1)
    }
}
