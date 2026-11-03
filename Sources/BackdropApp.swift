import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Security
import Darwin

struct BackdropPosition: Codable { var x = 50.0; var y = 50.0 }
struct BackdropSettings: Codable {
    var imageData: String
    var opacity = 0.40
    var blur = 0.0
    var panelOpacity = 0.72
    var position = BackdropPosition()
}

enum BackdropFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum OfficialApp {
    static let url = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    static let bundleID = "com.openai.codex"

    static func verify() throws {
        guard Bundle(url: url)?.bundleIdentifier == bundleID else {
            throw BackdropFailure.message("Supported ChatGPT app not found. This version requires /Applications/ChatGPT.app (com.openai.codex).")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let identity = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
              let code = code, let requirement = requirement else {
            throw BackdropFailure.message("Could not verify the ChatGPT app identity. The app has not been restarted.")
        }
        let result = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement)
        guard result == errSecSuccess else {
            let detail = SecCopyErrorMessageString(result, nil) as String? ?? String(result)
            throw BackdropFailure.message("Could not verify the ChatGPT signature (\(result)). The app has not been restarted or modified.\n\(detail)\nPreview is still available. Check your official ChatGPT installation before trying again.")
        }
    }

    static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BackdropFailure.message("Could not create a local connection.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw BackdropFailure.message("No local port is available.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { throw BackdropFailure.message("Could not read the local port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    @MainActor static func restart(port: Int) async throws {
        try verify() // Verify before interrupting any running process.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for app in running {
            guard app.bundleURL?.standardizedFileURL == url.standardizedFileURL else {
                throw BackdropFailure.message("ChatGPT is running from another location. Quit it manually, then try again.")
            }
            guard app.terminate() else {
                throw BackdropFailure.message("ChatGPT could not quit. Finish your current work, then quit it manually.")
            }
        }
        for _ in 0..<80 {
            if running.allSatisfy({ $0.isTerminated }) { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard running.allSatisfy({ $0.isTerminated }) else {
            throw BackdropFailure.message("ChatGPT is still running. Applying stopped without forcing it to quit.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1"]
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

@MainActor final class BackdropModel: ObservableObject {
    @Published var settings: BackdropSettings
    @Published var image: NSImage
    @Published var isAnimated = false
    @Published var mediaFrameCount = 1
    @Published var imageName = "Twilight Hills · Sample Background"
    @Published var status = "Preview your background, then apply it to ChatGPT"
    @Published var error: String?
    @Published var busy = false
    @Published var applied = false
    @Published var connected = false
    @Published var portText = ""
    @Published var showRestartConfirmation = false
    private let client = CDPClient()
    private var documentScript: String?
    private var debounce: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var targetOrigin: String?
    private var sessionPort: Int?
    private var recoveringApp = false
    private var actionTask: Task<Void, Never>?
    private var shuttingDown = false
    private var updateRequested = false
    private var registrationUncertain = false

    init() {
        let sample = Self.sampleBackground()
        image = NSImage(data: sample)!
        settings = BackdropSettings(imageData: "data:image/png;base64," + sample.base64EncodedString())
    }

    static func sampleBackground() -> Data {
        let size = NSSize(width: 1440, height: 1000)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(red: 0.04, green: 0.08, blue: 0.18, alpha: 1), NSColor(red: 0.13, green: 0.32, blue: 0.40, alpha: 1), NSColor(red: 0.57, green: 0.39, blue: 0.43, alpha: 1)])!.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        let moon = NSBezierPath(ovalIn: NSRect(x: 1040, y: 650, width: 145, height: 145))
        NSColor(red: 0.99, green: 0.86, blue: 0.72, alpha: 0.85).setFill(); moon.fill()
        for (offset, color) in [(0.0, NSColor(red: 0.13, green: 0.25, blue: 0.34, alpha: 1)), (140.0, NSColor(red: 0.08, green: 0.17, blue: 0.27, alpha: 1)), (280.0, NSColor(red: 0.035, green: 0.10, blue: 0.18, alpha: 1))] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 0)); path.line(to: NSPoint(x: 0, y: 450 - offset))
            path.curve(to: NSPoint(x: 1440, y: 440 - offset), controlPoint1: NSPoint(x: 470, y: 850 - offset), controlPoint2: NSPoint(x: 850, y: 90 - offset))
            path.line(to: NSPoint(x: 1440, y: 0)); path.close(); color.setFill(); path.fill()
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .webP, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image or animated GIF. Files stay on your Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let media = try BackdropMedia.load(url: url)
            image = media.image
            imageName = url.lastPathComponent
            isAnimated = media.isAnimated
            mediaFrameCount = media.frameCount
            settings.imageData = media.dataURL
            changed()
        } catch { self.error = error.localizedDescription }
    }

    func changed() {
        debounce?.cancel()
        guard applied && connected && !shuttingDown else { return }
        updateRequested = true
        guard !busy else { return }
        debounce = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self = self else { return }
                self.run {
                    repeat {
                        self.updateRequested = false
                        try await self.install()
                    } while self.updateRequested && !self.shuttingDown
                }
            } catch is CancellationError { }
            catch { self?.handle(error) }
        }
    }

    func applyPressed() {
        guard !busy else { return }
        if connected {
            run { try await self.install() }
        } else { showRestartConfirmation = true }
    }

    func restartAndApply() {
        run {
            self.status = "Checking the ChatGPT installation…"
            let port = try OfficialApp.availablePort()
            try await OfficialApp.restart(port: port)
            self.registrationUncertain = false
            self.recoveringApp = true
            self.portText = String(port)
            self.status = "Waiting for ChatGPT to open…"
            var lastError: Error = BackdropFailure.message("ChatGPT has not provided a connection endpoint yet.")
            let deadline = Date().addingTimeInterval(20)
            var found = false
            while Date() < deadline && !self.shuttingDown {
                do {
                    try await self.connect(port: port)
                    found = true
                    break
                } catch {
                    lastError = error
                    self.client.disconnect()
                    self.connected = false
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            guard found else { throw lastError }
            try await self.install()
            self.recoveringApp = false
        }
    }

    func connectExisting() {
        guard !connected else { return }
        run {
            guard let port = Int(self.portText) else { throw BackdropFailure.message("Enter an active local debug port.") }
            try OfficialApp.verify()
            try await self.connect(port: port)
            self.status = "Connected. Click Apply Background to enable it."
        }
    }

    func checkCompatibility() {
        run {
            try OfficialApp.verify()
            self.status = "ChatGPT verified. Apply when your work is finished."
        }
    }

    private static func isShell(_ target: DebugTarget) -> Bool {
        guard target.type == "page", let url = URLComponents(string: target.url) else { return false }
        return url.scheme == "app" && url.host == "-" && url.path == "/index.html" && url.user == nil && url.password == nil
    }

    private func connect(port: Int) async throws {
        let targets = try await CDPClient.discover(port: port).filter(Self.isShell)
        guard targets.count == 1, let target = targets.first else {
            throw BackdropFailure.message(targets.isEmpty ? "No supported ChatGPT main window found. Embedded browser tabs are excluded." : "Multiple main windows found. Keep one ChatGPT main window open, then try again.")
        }
        try await client.connect(target: target, port: port)
        targetOrigin = "app://-/index.html"
        sessionPort = port
        connected = true
        startMonitor()
    }

    private func source() throws -> String {
        guard let url = Bundle.main.url(forResource: "theme", withExtension: "js") else { throw BackdropFailure.message("The theme engine is missing. Rebuild ChatGPT Backdrop.") }
        let engine = try String(contentsOf: url, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let config = String(decoding: try encoder.encode(settings), as: UTF8.self)
        return """
        (() => {
          if (self !== top || location.protocol !== 'app:' || location.hostname !== '-' || location.pathname !== '/index.html') return {active:false,unsupported:true};
          \(engine)
          return globalThis.__chatGPTBackdrop.apply(\(config));
        })()
        """
    }

    private func install() async throws {
        guard connected && client.isConnected else { throw CDPError.disconnected }
        let script = try source()
        let result = try await client.command(method: "Runtime.evaluate", params: ["expression": script, "returnByValue": true, "awaitPromise": true, "allowUnsafeEvalBlockedByCSP": false])
        guard let remote = result["result"] as? [String: Any], let value = remote["value"] as? [String: Any], value["active"] as? Bool == true else {
            throw BackdropFailure.message("This window layout is not supported. No background was applied.")
        }
        applied = true
        // Register only for the verified main shell; the source itself also guards
        // origin, path and top frame. Remove the previous registration first.
        if let previous = documentScript {
            _ = try await client.command(method: "Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": previous])
            documentScript = nil
        }
        do {
            let registration = try await client.command(method: "Page.addScriptToEvaluateOnNewDocument", params: ["source": script])
            guard let identifier = registration["identifier"] as? String else { throw CDPError.malformedResponse }
            documentScript = identifier
        } catch {
            // A command can execute before its reply is lost. Never claim that
            // removing visible styles also removed an unacknowledged script.
            registrationUncertain = true
            throw error
        }
        applied = true
        status = "Background applied · Changes update live"
    }

    func restore() {
        debounce?.cancel()
        updateRequested = false
        run {
            if let identifier = self.documentScript {
                _ = try await self.client.command(method: "Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": identifier])
                self.documentScript = nil
            }
            _ = try await self.client.command(method: "Runtime.evaluate", params: ["expression": "globalThis.__chatGPTBackdrop?.restore()", "returnByValue": true, "allowUnsafeEvalBlockedByCSP": false])
            self.applied = false
            self.status = "Original appearance restored"
            if self.registrationUncertain {
                self.error = "The visible background was removed, but a reload setting could not be confirmed. Quit and reopen ChatGPT to finish cleanup."
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy && !shuttingDown else { return }
        debounce?.cancel()
        busy = true
        actionTask = Task {
            defer {
                busy = false
                actionTask = nil
                if updateRequested && applied && connected && !shuttingDown { changed() }
            }
            do { try await action() } catch { updateRequested = false; handle(error) }
        }
    }

    private func handle(_ failure: Error) {
        error = failure.localizedDescription
        if !client.isConnected {
            registrationUncertain = registrationUncertain || applied || documentScript != nil
            connected = false; applied = false; documentScript = nil
        }
        status = recoveringApp ? "Connection incomplete. Quit and reopen ChatGPT normally." : "Could not complete. See the details."
        recoveringApp = false
    }

    private func startMonitor() {
        guard !shuttingDown else { return }
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard let self = self else { return }
                if !self.client.isConnected {
                    self.registrationUncertain = self.registrationUncertain || self.applied || self.documentScript != nil
                    self.connected = false; self.applied = false; self.documentScript = nil
                    self.status = "Disconnected. Apply again to restore your background."
                    return
                }
            }
        }
    }

    func exportTheme() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "My theme.chatgpt-background.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Save your image and appearance settings in a theme file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; try encoder.encode(settings).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }

    func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max
            guard size < 20 * 1024 * 1024 else { throw BackdropFailure.message("The theme file exceeds 20 MB.") }
            var imported = try JSONDecoder().decode(BackdropSettings.self, from: Data(contentsOf: url))
            let media = try BackdropMedia.decode(dataURL: imported.imageData)
            imported.imageData = media.dataURL
            func clamp(_ x: Double, _ lower: Double, _ upper: Double) -> Double { x.isFinite ? min(upper, max(lower, x)) : lower }
            imported.opacity = clamp(imported.opacity, 0, 0.85); imported.blur = clamp(imported.blur, 0, 24)
            imported.panelOpacity = clamp(imported.panelOpacity, 0, 1)
            imported.position.x = clamp(imported.position.x, 0, 100); imported.position.y = clamp(imported.position.y, 0, 100)
            settings = imported; image = media.image; isAnimated = media.isAnimated
            mediaFrameCount = media.frameCount
            imageName = url.deletingPathExtension().lastPathComponent; changed()
        } catch { self.error = error.localizedDescription }
    }

    func finishAndQuit() async {
        shuttingDown = true
        debounce?.cancel(); monitor?.cancel()
        await actionTask?.value
        var cleanupFailed = registrationUncertain
        if connected && client.isConnected {
            do {
                if let identifier = documentScript { _ = try await client.command(method: "Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": identifier]); documentScript = nil }
                _ = try await client.command(method: "Runtime.evaluate", params: ["expression": "globalThis.__chatGPTBackdrop?.restore()", "returnByValue": true, "allowUnsafeEvalBlockedByCSP": false])
            } catch { cleanupFailed = true }
        }
        if cleanupFailed {
            let alert = NSAlert()
            alert.messageText = "Cleanup incomplete"
            alert.informativeText = "Quit and reopen ChatGPT to remove this background. App files have not been changed."
            alert.addButton(withTitle: "Got It, Quit")
            alert.runModal()
        }
        client.disconnect()
    }
}

final class BackdropAppDelegate: NSObject, NSApplicationDelegate {
    var model: BackdropModel?
    var quitting = false
    var cleanupDone = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cleanupDone { return .terminateNow }
        if quitting { return .terminateLater }
        quitting = true
        Task { @MainActor in await model?.finishAndQuit(); cleanupDone = true; sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct BackdropApp: App {
    @NSApplicationDelegateAdaptor(BackdropAppDelegate.self) var delegate
    @StateObject private var model = BackdropModel()
    var body: some Scene {
        WindowGroup("ChatGPT Backdrop") {
            BackdropView(model: model).preferredColorScheme(.dark)
                .onAppear {
                    delegate.model = model
                    if let icon = BackdropBrand.icon { NSApplication.shared.applicationIconImage = icon }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1000, height: 720)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private enum BackdropBrand {
    static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Backdrop-AppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

struct BackdropView: View {
    @ObservedObject var model: BackdropModel
    private let accent = Color(red: 0.39, green: 0.83, blue: 0.76)
    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top) {
                HStack(spacing: 14) {
                    if let icon = BackdropBrand.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 58, height: 58).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("BACKDROP / LOCAL EDITION").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2.5).foregroundStyle(accent)
                        Text("Your conversations. Your scenery.").font(.system(size: 28, weight: .semibold))
                        Text("Image & GIF backgrounds for ChatGPT · Files stay on your Mac").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 6) { Circle().fill(model.applied ? accent : .gray).frame(width: 6, height: 6); Text(model.applied ? "Applied" : "Preview Mode").font(.system(size: 11, weight: .medium)) }
                    .padding(.horizontal, 12).padding(.vertical, 7).background(.white.opacity(0.055), in: Capsule())
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    preview.frame(width: 580, height: 438).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 1))
                    HStack {
                        Image(systemName: model.isAnimated ? "play.rectangle" : "photo").foregroundStyle(accent)
                        Text(model.imageName).lineLimit(1).font(.system(size: 11))
                        if model.isAnimated {
                            Text("GIF · \(model.mediaFrameCount) frames").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(accent)
                        }
                        Spacer(); Text("Illustrative Preview").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("Preview shows the image and opacity. Your ChatGPT layout stays the same.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("01 / CHOOSE YOUR SCENERY").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Button(action: model.chooseImage) { Label("Choose Background…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 6) }.controlSize(.large)
                        Text("GIF, PNG, JPEG, WebP, HEIC, TIFF").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 15) {
                        Text("02 / SET THE MOOD").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        slider("Dim Overlay", value: $model.settings.opacity, range: 0...0.85, display: "\(Int(model.settings.opacity * 100))%")
                        slider("Background Blur", value: $model.settings.blur, range: 0...24, display: "\(Int(model.settings.blur)) px")
                        slider("Panel Opacity", value: $model.settings.panelOpacity, range: 0...1, display: "\(Int(model.settings.panelOpacity * 100))%")
                        slider("Horizontal Position", value: $model.settings.position.x, range: 0...100, display: "\(Int(model.settings.position.x))%")
                        slider("Vertical Position", value: $model.settings.position.y, range: 0...100, display: "\(Int(model.settings.position.y))%")
                    }
                    HStack { Button("Import Theme…", action: model.importTheme); Spacer(); Button("Save Theme…", action: model.exportTheme) }.font(.system(size: 11)).buttonStyle(.link)
                }.frame(width: 280)
            }
            Divider()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) { if model.busy { ProgressView().controlSize(.small) }; Text(model.status).font(.system(size: 12, weight: .medium)) }
                    Text("First apply asks to restart ChatGPT. Quitting this tool removes the background.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Original", action: model.restore).disabled(!model.connected || model.busy)
                Button(action: model.applyPressed) { Text(model.busy ? "Working…" : "Apply Background").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 22).padding(.vertical, 10).foregroundStyle(Color(red: 0.03, green: 0.10, blue: 0.10)).background(accent.opacity(model.busy ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 10)) }
                    .buttonStyle(.plain).disabled(model.busy)
            }
            DisclosureGroup("Advanced: Connect to a Debug Session") {
                HStack { Button("Check App", action: model.checkCompatibility).disabled(model.busy); Text("Local Port").font(.system(size: 11)); TextField("e.g. 54321", text: $model.portText).frame(width: 100); Button("Connect", action: model.connectExisting).disabled(model.busy || model.connected); Spacer(); Text("Local main window only.").font(.system(size: 10)).foregroundStyle(.secondary) }.padding(.top, 8)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(30).frame(width: 948).background(Color(red: 0.055, green: 0.065, blue: 0.085))
        .alert("Restart ChatGPT to Apply", isPresented: $model.showRestartConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restart and Apply") { model.restartAndApply() }
        } message: { Text("This interrupts active ChatGPT tasks, including a task running in this conversation. Finish your work before continuing.\n\nThe tool opens a local debug connection to apply the background. It does not modify ChatGPT app files.") }
        .alert("Could Not Complete", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Got It") { model.error = nil } } message: { Text(model.error ?? "") }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(spacing: 5) { HStack { Text(title).font(.system(size: 11)); Spacer(); Text(display).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }; Slider(value: value, in: range).tint(accent).onChange(of: value.wrappedValue) { model.changed() } }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                let scale = max(geometry.size.width / max(1, model.image.size.width), geometry.size.height / max(1, model.image.size.height))
                let width = model.image.size.width * scale
                let height = model.image.size.height * scale
                Group {
                    if model.isAnimated { AnimatedBackdropImage(image: model.image) }
                    else { Image(nsImage: model.image).resizable() }
                }.frame(width: width, height: height).allowsHitTesting(false)
                    .offset(x: (geometry.size.width - width) * (model.settings.position.x / 100 - 0.5), y: (geometry.size.height - height) * (model.settings.position.y / 100 - 0.5))
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped().blur(radius: model.settings.blur / 2)
                    .overlay(Color.black.opacity(model.settings.opacity))
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack(spacing: 6) { Image(systemName: "circle.hexagongrid"); Text("ChatGPT").fontWeight(.semibold) }.font(.system(size: 11))
                        Label("New Chat", systemImage: "square.and.pencil").font(.system(size: 10))
                        Label("Search Chats", systemImage: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                        Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                        Text("RECENT CHATS").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text("A Weekend Away").font(.system(size: 10))
                        Text("The Next Good Idea").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 6) { Circle().fill(accent.opacity(0.3)).frame(width: 18, height: 18); Text("Your Workspace").font(.system(size: 9)) }
                    }.padding(16).frame(width: 143).background(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(model.settings.panelOpacity))
                    VStack(spacing: 0) {
                        HStack { Text("ChatGPT").font(.system(size: 10, weight: .medium)); Image(systemName: "chevron.down").font(.system(size: 8)); Spacer(); Image(systemName: "ellipsis").font(.system(size: 10)) }.padding(18)
                        Spacer()
                        Image(systemName: "sparkle").font(.system(size: 25, weight: .light)).foregroundStyle(accent).padding(.bottom, 12)
                        Text("Where shall we begin?").font(.system(size: 19, weight: .medium))
                        Text("A favorite view. A little room to think.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).padding(.top, 9)
                        Spacer()
                        HStack { Text("Send a message…").foregroundStyle(.white.opacity(0.6)); Spacer(); Image(systemName: "arrow.up.circle.fill").foregroundStyle(accent) }
                            .font(.system(size: 11)).padding(14).background(Color(red: 0.10, green: 0.11, blue: 0.15).opacity(model.settings.panelOpacity), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12))).padding(.horizontal, 20)
                        Text("A different view, the same conversations.").font(.system(size: 8)).foregroundStyle(.white.opacity(0.45)).padding(.vertical, 12)
                    }
                }
            }
        }
    }
}
