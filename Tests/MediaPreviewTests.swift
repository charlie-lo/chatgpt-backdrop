import AppKit
import Foundation
import SwiftUI

@MainActor private final class MediaPreviewModel: ObservableObject {
    let image: NSImage
    @Published var sliderUpdate = 0
    @Published var result = "Checking native animation…"

    init(image: NSImage) { self.image = image }
}

private struct MediaPreviewContent: View {
    @ObservedObject var model: MediaPreviewModel

    var body: some View {
        VStack(spacing: 18) {
            Text("Native GIF Preview Test").font(.title3.weight(.semibold))
            AnimatedBackdropImage(image: model.image)
                .frame(width: 288, height: 192)
                .opacity(model.sliderUpdate.isMultiple(of: 2) ? 1 : 0.99)
            Text("Red → Green → Blue · 0.24 s per frame").font(.caption)
            Text("Preview updates: \(model.sliderUpdate)").font(.caption)
            Text(model.result).font(.caption).textSelection(.enabled)
            Button("Quit Test") { NSApp.terminate(nil) }
        }
        .padding(22)
        .frame(width: 400, height: 400)
    }
}

/// An isolated visible app harness. It never connects to or controls ChatGPT.
/// Launch the generated test .app with Computer Use, not a shell GUI command.
@MainActor private final class MediaPreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: MediaPreviewModel?
    private var imageObservation: NSKeyValueObservation?
    private var timer: Timer?
    private let startedAt = Date()
    private var samples: [[String: Any]] = []
    private var colors = Set<String>()
    private var frames = Set<Int>()
    private var lastFrame = -1
    private var imageAssignments = 0
    private var updateStarted = false
    private var updateChecked = false
    private var sameImageAfterUpdate = false
    private var nonzeroFrameAfterUpdate = false
    private var expectedImage: NSImage?

    private var resultURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("media-preview-result.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let fixture = Bundle.main.url(forResource: "animation", withExtension: "gif") else {
                throw NSError(domain: "MediaPreviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Animation fixture is missing"])
            }
            let media = try BackdropMedia.load(url: fixture)
            expectedImage = media.image
            let state = MediaPreviewModel(image: media.image)
            model = state
            let content = NSHostingView(rootView: MediaPreviewContent(model: state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Backdrop Media Tests"
            window.contentView = content
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
            timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sample() }
            }
        } catch {
            save(["passed": false, "error": error.localizedDescription])
        }
    }

    private func findImageView(in view: NSView?) -> NSImageView? {
        guard let view = view else { return nil }
        if let image = view as? NSImageView { return image }
        for child in view.subviews {
            if let image = findImageView(in: child) { return image }
        }
        return nil
    }

    private func currentFrame(_ view: NSImageView) -> Int {
        let rep = view.image?.representations.compactMap { $0 as? NSBitmapImageRep }.first
        return (rep?.value(forProperty: .currentFrame) as? NSNumber)?.intValue ?? -1
    }

    private func sample() {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard let view = findImageView(in: window?.contentView) else {
            if elapsed > 8 { finish(error: "NSImageView was not mounted") }
            return
        }
        if imageObservation == nil {
            imageObservation = view.observe(\.image, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.imageAssignments += 1 }
            }
        }
        let index = currentFrame(view)
        frames.insert(index)
        var color = "unknown"
        var rgb: [Double] = []
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Read raw cached bitmap channels, avoiding ColorSync IPC during
            // this isolated rendering check. The cached view uses RGB samples.
            if bitmap.bitsPerSample > 0 && bitmap.bitsPerSample <= 16 && bitmap.samplesPerPixel >= 3 {
                var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
                bitmap.getPixel(&pixel, atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
                let first = bitmap.hasAlpha && bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
                let scale = Double((1 << bitmap.bitsPerSample) - 1)
                rgb = pixel[first..<(first + 3)].map { Double($0) / scale }
                // Compositing can lift the other channels. Require one clear
                // dominant channel rather than exact unmanaged 0/1 values.
                let ranked = rgb.enumerated().sorted { $0.element > $1.element }
                if ranked[0].element >= 0.6 && ranked[0].element - ranked[1].element >= 0.25 {
                    color = ["red", "green", "blue"][ranked[0].offset]
                }
            }
        }
        if color != "unknown" { colors.insert(color) }
        samples.append(["seconds": elapsed, "frame": index, "renderedColor": color,
                        "rgb": rgb, "sameImage": view.image === expectedImage,
                        "animates": view.animates])
        if samples.count.isMultiple(of: 6) {
            model?.result = "Captured \(samples.count) samples · \(colors.count) frame colors"
            save(["phase": "sampling", "processID": ProcessInfo.processInfo.processIdentifier,
                  "bundleID": Bundle.main.bundleIdentifier ?? "unknown", "sampleCount": samples.count,
                  "renderedColors": colors.sorted(), "observedFrames": frames.sorted()])
        }

        // Trigger the same kind of outer SwiftUI update as an opacity slider,
        // immediately after observing a transition off the first GIF frame.
        if !updateStarted && lastFrame == 0 && index > 0 {
            updateStarted = true
            model?.sliderUpdate += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak view] in
                guard let self = self, let view = view else { return }
                self.sameImageAfterUpdate = view.image === self.expectedImage
                self.nonzeroFrameAfterUpdate = self.currentFrame(view) > 0
                self.updateChecked = true
                self.model?.sliderUpdate += 1
            }
        }
        lastFrame = index
        if elapsed >= 2.4 && updateChecked { finish(error: nil) }
        else if elapsed > 8 { finish(error: "Animation or update check did not complete") }
    }

    private func finish(error: String?) {
        timer?.invalidate()
        timer = nil
        let frameAdvanced = frames.filter { $0 >= 0 }.count >= 2
        let multipleRenderedColors = colors.count >= 2
        let updatePreservedPlayback = updateChecked && sameImageAfterUpdate && nonzeroFrameAfterUpdate && imageAssignments == 0
        let passed = error == nil && frameAdvanced && multipleRenderedColors && updatePreservedPlayback
        var result: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "passed": passed,
            "nativeFrameAdvanced": frameAdvanced,
            "renderedMultipleColors": multipleRenderedColors,
            "renderedColors": colors.sorted(),
            "observedFrames": frames.sorted(),
            "sameImageAfterSwiftUIUpdate": sameImageAfterUpdate,
            "nonzeroFrameAfterSwiftUIUpdate": nonzeroFrameAfterUpdate,
            "imageAssignmentsDuringAnimation": imageAssignments,
            "updatePreservedPlayback": updatePreservedPlayback,
            "sampleCount": samples.count,
            "samples": samples
        ]
        if let error = error { result["error"] = error }
        save(result)
        model?.result = passed ? "Passed: animation survives preview updates" : "Failed: see media-preview-result.json"
        window?.title = passed ? "Backdrop Media Tests — Passed" : "Backdrop Media Tests — Failed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
    }

    private func save(_ result: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resultURL, options: .atomic)
        } catch {
            NSLog("Could not write media preview test result: %@", error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct MediaPreviewTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MediaPreviewDelegate()
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Media Tests", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        app.mainMenu = menu
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) { }
    }
}
