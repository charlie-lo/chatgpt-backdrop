import AppKit
import WebKit
import Foundation

private func writeTestResult(to url: URL?, success: Bool, checks: [String: Any]? = nil, error: String? = nil) {
    guard let url else { return }
    var result: [String: Any] = ["success": success, "timestamp": ISO8601DateFormatter().string(from: Date())]
    if let checks { result["assertions"] = checks }
    if let error { result["error"] = error }
    do {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    } catch {
        fputs("Could not write DOM test results: \(error.localizedDescription)\n", stderr)
    }
}

/// Exercises the original styling engine in an isolated, in-memory WebKit page.
/// It never opens, inspects, restarts, or connects to ChatGPT.
@main
@MainActor
struct ThemeTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let resultURL = (Bundle.main.object(forInfoDictionaryKey: "BackdropTestResultPath") as? String)
            .map { URL(fileURLWithPath: $0) }
        do {
            let sourceURL: URL
            if CommandLine.arguments.count == 2 {
                sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
            } else if CommandLine.arguments.count == 1,
                      let bundled = Bundle.main.url(forResource: "theme", withExtension: "js") {
                sourceURL = bundled
            } else {
                throw NSError(domain: "ThemeTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Usage: ThemeTests /absolute/path/to/theme.js, or launch the bundled test app."])
            }
            let engine = try String(contentsOf: sourceURL, encoding: .utf8)
            let runner = Runner(engine: engine, resultURL: resultURL)
            runner.start()
            withExtendedLifetime(runner) { app.run() }
        } catch {
            fputs("Theme tests could not start: \(error.localizedDescription)\n", stderr)
            writeTestResult(to: resultURL, success: false, error: "Tests could not start: \(error.localizedDescription)")
            exit(1)
        }
    }
}

@MainActor
final class Runner: NSObject, WKNavigationDelegate {
    private let engine: String
    private let resultURL: URL?
    private var webView: WKWebView!
    private var window: NSWindow?
    private var timeout: Timer?
    private var finished = false

    init(engine: String, resultURL: URL? = nil) {
        self.engine = engine
        self.resultURL = resultURL
    }

    func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        webView.navigationDelegate = self
        // WebKit pauses animation frames for a detached or fully hidden view.
        // This accessory window shows only the independent local test fixture.
        let window = NSWindow(contentRect: NSRect(x: 180, y: 120, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Backdrop DOM Tests — local fixture"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(webView)
        timeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(error: "WebKit DOM tests timed out after 45 seconds.")
            }
        }
        let fixture = """
        <!doctype html>
        <html class="dark" data-codex-window-type="electron" data-chatgpt-backdrop="prior-root"><head>
        <meta charset="UTF-8">
        <style>
        html,body{margin:0;background:rgb(24,24,24);color:white}
        #root{min-height:100vh;background:rgb(31,31,31)}
        main{background:rgb(42,42,42)}
        pre{background:rgb(12,13,14)}
        [role=dialog]{background:rgb(44,45,46)}
        [data-message-author-role]{background:rgb(21,22,23)}
        :root{--elevation-composer:0 16px 48px rgba(0,0,0,.8);--elevation-composer-dark:0 20px 56px rgba(0,0,0,.9)}
        [data-app-shell-page-sidebar]{background:rgb(24,24,27)}
        aside.app-shell-left-panel{background:rgb(24,24,27)}
        ._FloatingHeader_fixture[data-app-shell-left-panel-appearance]{background:rgb(24,24,27)}
        .sidebar-navigation{background:rgba(24,24,27,.65)}
        ._MainContentTopFade_fixture{height:24px;background-image:linear-gradient(rgb(24,24,27),transparent)}
        ._background_fixture._surface_fixture{height:180px;background:rgb(24,24,27)}
        ._background_fixture._fade_fixture,._background_fixture._combined_fixture{height:32px;background-image:linear-gradient(to top,rgb(24,24,27),transparent)}
        ._ComposerLayoutRoot_fixture{--composer-layout-surface-background:rgb(24,24,27);--composer-layout-surface-shadow:var(--elevation-composer)}
        ._ComposerLayoutRoot_fixture[data-composer-dark]{--composer-layout-surface-shadow:var(--elevation-composer-dark)}
        ._ComposerLayoutRoot_fixture:not([data-composer-utility-bar-variant=home]),[data-composer-utility-bar-variant=home] ._ComposerLayoutBody_fixture{background-color:var(--composer-layout-surface-background);box-shadow:var(--composer-layout-surface-shadow)}
        ._ComposerLayoutRoot_fixture[data-composer-surface-variant=document],._ComposerLayoutRoot_fixture[data-composer-surface-variant=inline]{--composer-layout-surface-background:transparent;--composer-layout-surface-shadow:none}
        ._ComposerLayoutRoot_fixture[data-composer-surface-variant=document]:focus-within{--composer-layout-surface-background:rgb(40,40,43)}
        #unrelated-gradient{background-image:linear-gradient(red,blue);box-shadow:0 4px 16px rgba(0,0,0,.5)}
        pre{box-shadow:0 2px 6px rgba(0,0,0,.4)}
        [role=menu]{background:rgb(40,42,44);box-shadow:0 8px 20px rgba(0,0,0,.7)}
        ._PageSurface_fixture{box-shadow:0 0 0 1px rgba(255,255,255,.1),-8px 0 32px rgba(0,0,0,.7)}
        :root{--radius-2xl-base:16px;--corner-radius-scale:1.25;--radius-2xl:calc(var(--radius-2xl-base) * var(--corner-radius-scale))}
        .app-shell-left-panel{position:relative;width:120px;height:160px}
        [data-codex-window-type=electron]:not([data-codex-window-chrome=application-menu]) .app-shell-left-panel:not([data-app-shell-left-panel-appearance=content-surface]):after{inset:0 calc(-1 * var(--radius-2xl)) 0 auto;width:var(--radius-2xl);background:inherit;content:"";pointer-events:none;position:absolute}
        .app-shell-left-panel[data-app-shell-left-panel-appearance=content-surface]:after{width:8px;content:"";background-image:linear-gradient(red,blue);pointer-events:none}
        #sidebar-resize-wrapper{position:absolute;inset:0 0 0 auto;width:16px;transform:translateX(8px);z-index:2}
        #sidebar-resize-handle{position:relative;width:100%;height:100%;cursor:col-resize;touch-action:none;pointer-events:auto}
        #sidebar-resize-handle:after{content:"";position:absolute;inset:0;background:transparent}
        .sidebar-resize-handle-line{position:absolute;inset:0 auto 0 50%;width:1px;background:rgb(90,94,100);pointer-events:none}
        :root{--app-shell-sidebar-divider:rgba(255,255,255,.12)}
        ._MainContentLeftBorder_fixture{border-left:.5px solid var(--app-shell-sidebar-divider)}
        #root{position:relative;display:flow-root;--height-titlebar:44px;--app-shell-titlebar-height:var(--height-titlebar)}
        #page-shadow,#page-with-controls{position:absolute;top:44px;left:0}
        #titlebar{position:fixed;left:0;right:0;top:0;height:var(--app-shell-titlebar-height);z-index:30;-webkit-app-region:drag}
        #titlebar-control{position:absolute;left:12px;top:8px;width:28px;height:24px;pointer-events:auto;-webkit-app-region:no-drag}
        #titlebar-label{margin-left:60px}
        #root[data-app-shell-page-surface=true] #sidebar{margin-top:var(--app-shell-titlebar-height)}
        #sidebar{display:flex;overflow:visible}
        #navigation-rail{flex:0 0 52px;width:52px;pointer-events:auto}
        #sidebar-content{flex:1;min-width:0}
        #peeking-sidebar{position:absolute;left:0;top:420px;width:90px;height:80px}
        /* Native PageSurfaceLayout reserves one spacing unit below its flex row. */
        .bottom-layout-fixture{position:fixed;right:0;bottom:0;display:flex;flex-direction:column;box-sizing:border-box;width:320px;height:180px;--spacing:4px;--app-shell-titlebar-height:44px;padding-block-end:var(--spacing);padding-inline-end:var(--spacing)}
        #bottom-workspace{position:relative;display:flex;flex:1;min-height:0;max-height:100%;width:100%}
        #bottom-sidebar{display:flex;flex-direction:column;flex-shrink:0;height:auto;margin-top:var(--app-shell-titlebar-height)}
        #bottom-navigation{display:flex;flex-direction:column;flex:1;box-sizing:border-box;padding-bottom:4px}
        #bottom-control{margin-top:auto;height:24px}
        #bottom-main{flex:1;margin-top:var(--app-shell-titlebar-height);border-radius:12px}
        </style>
        <script>
        \(engine)
        window.fixtureImage = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/mZQAAAAASUVORK5CYII=';
        window.fixtureGIF87 = 'data:image/gif;base64,\(Self.animatedGIFBase64)';
        window.fixtureGIF = 'data:image/gif;base64,' + btoa('GIF89a' + atob('\(Self.animatedGIFBase64)').slice(6));
        window.titlebarControlClicks = 0;
        window.bottomControlClicks = 0;
        window.beforeDOM = __chatGPTBackdrop.apply({imageData: fixtureImage});
        </script></head><body>
        <div id="root" data-app-shell-page-sidebar="true" data-app-shell-page-surface="true" data-app-shell-frame>
          <div id="page-shadow" class="_PageSurface_fixture" aria-hidden="true"></div>
          <div id="page-with-controls" class="_PageSurface_fixture" aria-hidden="true"><button type="button">Preserved page controls</button></div>
          <header id="titlebar" data-app-shell-titlebar><button id="titlebar-control" type="button" onclick="titlebarControlClicks++">Back</button><span id="titlebar-label">Title</span><div data-app-shell-main-content-top-fade="visible"><div id="header-fade" class="_MainContentTopFade_fixture" aria-hidden="true"></div></div></header>
          <aside id="sidebar" class="app-shell-left-panel" data-app-shell-left-panel-appearance="translucent"><div id="navigation-rail">Home</div><div id="sidebar-content"><div id="sidebar-header" class="_FloatingHeader_fixture" data-app-shell-left-panel-appearance="translucent">Sidebar</div><nav id="sidebar-navigation" class="sidebar-navigation">Navigation</nav></div><div id="sidebar-resize-wrapper" class="group/panel-resizer"><div id="sidebar-resize-handle" role="separator" aria-orientation="vertical" tabindex="0"><div id="sidebar-resize-line" class="sidebar-resize-handle-line"></div></div></div></aside>
          <aside id="content-sidebar" class="app-shell-left-panel" data-app-shell-left-panel-appearance="content-surface">Content surface</aside>
          <aside id="peeking-sidebar" class="app-shell-left-panel" data-app-shell-left-panel-appearance="translucent" data-slate-sidebar-peeking="true">Peeking sidebar</aside>
          <main id="main" class="_MainContentLeftBorder_fixture" data-chatgpt-backdrop-surface="prior-main" data-app-shell-page-surface>
            <article data-message-author-role="assistant"><p>Message text</p><pre><code>const unchanged = true;</code></pre></article>
            <div role="dialog"><div data-message-author-role="assistant">Protected dialog content</div><div data-thread-footer-background><div id="dialog-decoration" class="_background_fixture _fade_fixture" aria-hidden="true"></div></div><div id="dialog-left-border" class="_MainContentLeftBorder_fixture">Native dialog border</div></div>
            <div id="unrelated-gradient">Unrelated content decoration</div>
            <div id="native-menu" role="menu"><div data-composer-surface-variant="default">Native menu</div></div>
            <div id="document-composer" class="_ComposerLayoutRoot_fixture" data-composer-surface-variant="document"><div contenteditable="true">Document editor</div></div>
            <div id="inline-composer" class="_ComposerLayoutRoot_fixture" data-composer-surface-variant="inline"><div contenteditable="true">Inline editor</div></div>
            <div id="thread-scroll" class="thread-scroll-container" data-thread-footer-background style="--thread-footer-background-offset:0px">
              <div><div aria-hidden="true" class="pointer-events-none sticky bottom-0"><div id="footer-fade" class="_background_fixture _fade_fixture pointer-events-none absolute" aria-hidden="true"></div></div></div>
              <div id="thread-footer" data-thread-scroll-footer="true"><div id="footer-surface" class="_background_fixture _surface_fixture pointer-events-none absolute bg-surface" aria-hidden="true"></div><div data-pip-obstacle="thread-footer"><form data-chatgpt-composer data-thread-find-composer="true" data-composer-placement="thread"><section id="thread-composer" class="_ComposerLayoutRoot_fixture" data-composer-dark data-composer-surface-variant="default" data-composer-utility-bar-variant="default" data-composer-layout="single-line"><div id="composer-body" class="_ComposerLayoutBody_fixture" data-composer-body data-composer-layout="single-line"><div contenteditable="true" id="prompt-textarea">Composer</div></div><button id="composer-control" type="button">Send</button></section></form></div></div>
              <div id="footer-combined" class="_background_fixture _combined_fixture pointer-events-none absolute" aria-hidden="true"></div>
              <div id="footer-with-controls" class="_background_fixture _fade_fixture" aria-hidden="true"><button type="button">Preserved footer controls</button></div>
            </div>
            <section id="home-composer" class="_ComposerLayoutRoot_fixture" data-composer-surface-variant="default" data-composer-utility-bar-variant="home"><div id="home-composer-body" class="_ComposerLayoutBody_fixture" data-composer-body>Home composer body</div></section>
          </main>
          <section id="bottom-layout" class="bottom-layout-fixture" data-app-shell-frame data-app-shell-page-surface="true" data-app-shell-page-sidebar="true"><div id="bottom-workspace" data-app-shell-workspace-row><aside id="bottom-sidebar" class="app-shell-left-panel" data-app-shell-left-panel-appearance="translucent"><nav id="bottom-navigation"><button id="bottom-control" type="button" onclick="bottomControlClicks++">Bottom control</button></nav></aside><div id="bottom-main" data-app-shell-main-surface="default">Main pane</div></div></section>
        </div>
        </body></html>
        """
        // The synthetic base is used only as the document's in-memory origin.
        // The fixture has no external scripts, styles, fonts, or image URLs.
        webView.loadHTMLString(fixture, baseURL: URL(string: "https://backdrop-test.invalid/"))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        let isFixture = url == nil || url?.absoluteString == "about:blank" || url?.host == "backdrop-test.invalid"
        decisionHandler(isFixture ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            do {
                let value = try await webView.callAsyncJavaScript(Self.assertions, arguments: [:], in: nil, contentWorld: .page)
                guard var object = value as? [String: Any],
                      var checks = object["checks"] as? [[String: Any]], let self else {
                    self?.finish(error: "WebKit returned an unexpected result: \(String(describing: value))")
                    return
                }
                if object["gifSupported"] as? Bool == true {
                    let animation = await self.verifyGIFAnimation()
                    checks.append(contentsOf: animation.checks)
                    object["gifAnimation"] = animation.diagnostic
                    object["checks"] = checks
                    object["passed"] = checks.filter { ($0["pass"] as? Bool) == true }.count
                    object["total"] = checks.count
                }
                let passed = checks.filter { ($0["pass"] as? Bool) == true }.count
                let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                if let data, let json = String(data: data, encoding: .utf8) { print(json) }
                if checks.contains(where: { ($0["pass"] as? Bool) != true }) {
                    self.finish(error: "One or more DOM assertions failed.", assertions: object)
                } else {
                    print("PASS: \(passed) real WebKit DOM assertions")
                    self.finish(assertions: object)
                }
            } catch {
                self?.finish(error: "WebKit assertion error: \(error.localizedDescription)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error: "Fixture load failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error: "Fixture provisional load failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(error: "WebKit content process terminated.")
    }

    private func verifyGIFAnimation() async -> (checks: [[String: Any]], diagnostic: [String: Any]) {
        let names = ["animated GIF CSS background renders multiple native frames",
                     "GIF background keeps animating after control changes"]
        var samples: [[Double]] = []
        var labels: [Int] = []
        do {
            for index in 0..<12 {
                if index == 6 {
                    _ = try await webView.callAsyncJavaScript("""
                    globalThis.__chatGPTBackdrop.apply({imageData: fixtureGIF, opacity: 0, blur: 4, panelOpacity: 0, position: {x: 35, y: 60}});
                    return globalThis.__chatGPTBackdrop.status();
                    """, arguments: [:], in: nil, contentWorld: .page)
                }
                try await Task.sleep(nanoseconds: 130_000_000)
                let configuration = WKSnapshotConfiguration()
                configuration.rect = NSRect(x: 400, y: 20, width: 16, height: 16)
                configuration.snapshotWidth = 16
                configuration.afterScreenUpdates = true
                let snapshot = try await webView.takeSnapshot(configuration: configuration)
                guard let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
                    throw NSError(domain: "ThemeTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "The native GIF snapshot has no readable RGB pixel."])
                }
                let rgb = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
                samples.append(rgb)
                // The original fixture contains full red, green, and blue
                // frames. Dominant channels survive display color conversion.
                let dominant = rgb.enumerated().max { $0.element < $1.element }?.offset ?? -1
                labels.append((rgb.max() ?? 0) - (rgb.min() ?? 0) > 0.3 ? dominant : -1)
            }
            let before = Set(labels.prefix(6).filter { $0 >= 0 })
            let after = Set(labels.suffix(6).filter { $0 >= 0 })
            return ([
                ["name": names[0], "pass": before.count >= 2],
                ["name": names[1], "pass": after.count >= 2]
            ], ["samplesRGB": samples, "dominantChannels": labels,
                "distinctFramesBeforeControls": before.count, "distinctFramesAfterControls": after.count])
        } catch {
            return (names.map { ["name": $0, "pass": false] },
                    ["error": error.localizedDescription, "samplesRGB": samples, "dominantChannels": labels])
        }
    }

    private func finish(error: String? = nil, assertions: [String: Any]? = nil) {
        guard !finished else { return }
        finished = true
        timeout?.invalidate()
        webView?.stopLoading()
        window?.orderOut(nil)
        writeTestResult(to: resultURL, success: error == nil, checks: assertions, error: error)
        if let error { fputs("FAIL: \(error)\n", stderr); exit(1) }
        exit(0)
    }

    // Original ImageIO fixture: three full solid frames, 0.24 s each, looped.
    private static let animatedGIFBase64 = "R0lGODdhYABAAKIAAAAAAP8mAAQz/wD5AP///wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFGAAFACwAAAAAYABAAAADWBi63P4wykmrvTjrzbv/YCiOZGmeaKqubOu+cCzPdG3feK7vfO//wKBwSCwaj8ikcslsOp/QqHRKrVqv2Kx2y+16v+CweEwum8/otHrNbrvf8Lh8Tq/bXwkAIfkEBRgABQAsAAAAAGAAQAAAA1g4utz+MMpJq7046827/2AojmRpnmiqrmzrvnAsz3Rt33iu73zv/8CgcEgsGo/IpHLJbDqf0Kh0Sq1ar9isdsvter/gsHhMLpvP6LR6zW673/C4fE6v218JACH5BAUYAAUALAAAAABgAEAAAANYKLrc/jDKSau9OOvNu/9gKI5kaZ5oqq5s675wLM90bd94ru987//AoHBILBqPyKRyyWw6n9CodEqtWq/YrHbL7Xq/4LB4TC6bz+i0es1uu9/wuHxOr9tfCQA7"

    private static let assertions = #"""
    const checks = [];
    const test = (name, condition) => { checks.push({name, pass: !!condition}); };
    // Let the engine's observer and RAF finish in a genuinely visible WebView.
    // A bounded fallback reports stalled rendering rather than hanging forever.
    let settleTimeouts = 0;
    const wait = () => new Promise(resolve => {
      const timer = setTimeout(() => { settleTimeouts++; resolve(); }, 2000);
      requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(timer); resolve(); }));
    });
    const api = globalThis.__chatGPTBackdrop;
    test('early injection queues document readiness', beforeDOM.pending === true && beforeDOM.active === false);
    test('early apply completes at DOMContentLoaded', api.status().active === true);
    api.restore();
    const baseline = document.documentElement.outerHTML;
    const code = document.querySelector('pre');
    const dialog = document.querySelector('[role=dialog] [data-message-author-role]');
    const codeBG = getComputedStyle(code).backgroundColor;
    const dialogBG = getComputedStyle(dialog).backgroundColor;
    const codeShadow = getComputedStyle(code).boxShadow;
    const unrelated = document.getElementById('unrelated-gradient');
    const unrelatedImage = getComputedStyle(unrelated).backgroundImage;
    const unrelatedShadow = getComputedStyle(unrelated).boxShadow;
    const nativeMenu = document.getElementById('native-menu');
    const menuBG = getComputedStyle(nativeMenu).backgroundColor;
    const menuShadow = getComputedStyle(nativeMenu).boxShadow;
    const dialogDecoration = document.getElementById('dialog-decoration');
    const dialogDecorationImage = getComputedStyle(dialogDecoration).backgroundImage;
    const pageWithControls = document.getElementById('page-with-controls');
    const pageControlShadow = getComputedStyle(pageWithControls).boxShadow;
    const originalComposer = document.getElementById('thread-composer').cloneNode(true);
    const nativeSidebar = document.getElementById('sidebar');
    const nativeSidebarStyle = nativeSidebar.getAttribute('style');
    const nativeSidebarRect = nativeSidebar.getBoundingClientRect();
    const nativeSidebarDocumentTop = nativeSidebarRect.top + scrollY;
    const nativeFrame = document.getElementById('root');
    const nativeFrameStyle = nativeFrame.getAttribute('style');
    const bottomFrame = document.getElementById('bottom-layout');
    const bottomSidebar = document.getElementById('bottom-sidebar');
    const bottomMain = document.getElementById('bottom-main');
    const bottomControl = document.getElementById('bottom-control');
    const bottomFrameStyle = bottomFrame.getAttribute('style');
    const bottomSidebarStyle = bottomSidebar.getAttribute('style');
    const nativeBottomGap = bottomFrame.getBoundingClientRect().bottom - bottomSidebar.getBoundingClientRect().bottom;
    const nativeBottomTop = bottomSidebar.getBoundingClientRect().top;
    const nativeBottomInlineInset = getComputedStyle(bottomFrame).paddingInlineEnd;
    const nativeBottomRadius = getComputedStyle(bottomMain).borderRadius;
    const bottomGap = () => bottomFrame.getBoundingClientRect().bottom - bottomSidebar.getBoundingClientRect().bottom;
    const titlebar = document.getElementById('titlebar');
    const titlebarControl = document.getElementById('titlebar-control');
    const titlebarControlRect = titlebarControl.getBoundingClientRect();
    const titlebarControlPointer = getComputedStyle(titlebarControl).pointerEvents;
    const originalAfter = getComputedStyle(nativeSidebar, '::after');
    const originalAfterContent = originalAfter.content;
    const nativeMainBorderWidth = getComputedStyle(document.getElementById('main')).borderLeftWidth;
    const dialogBorderColor = getComputedStyle(document.getElementById('dialog-left-border')).borderLeftColor;
    const contentSidebar = document.getElementById('content-sidebar');
    const contentPseudoImage = getComputedStyle(contentSidebar, '::after').backgroundImage;
    const resizeWrapper = document.getElementById('sidebar-resize-wrapper');
    const resizeHandle = document.getElementById('sidebar-resize-handle');
    const resizeLine = document.getElementById('sidebar-resize-line');
    const nativeResize = {
      width: getComputedStyle(resizeWrapper).width,
      transform: getComputedStyle(resizeWrapper).transform,
      cursor: getComputedStyle(resizeHandle).cursor,
      pointerEvents: getComputedStyle(resizeHandle).pointerEvents,
      touchAction: getComputedStyle(resizeHandle).touchAction,
      lineWidth: getComputedStyle(resizeLine).width,
      lineColor: getComputedStyle(resizeLine).backgroundColor,
      pseudoBackground: getComputedStyle(resizeHandle, '::after').backgroundColor
    };
    const alpha = (node, pseudo) => {
      const color = getComputedStyle(node, pseudo).backgroundColor;
      if (color === 'transparent') return 0;
      const numbers = color.match(/[\d.]+/g).map(Number);
      return numbers.length > 3 ? numbers[3] : 1;
    };
    const decorationAbsent = node => {
      const style = getComputedStyle(node);
      return style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0 ||
        (style.backgroundImage === 'none' && alpha(node) === 0);
    };
    api.apply({imageData: fixtureImage, opacity: 9, blur: -3, panelOpacity: 2, position: {x: -3, y: 400}});
    const layer = document.querySelector('[data-chatgpt-backdrop-layer]');
    test('creates one non-interactive layer', !!layer && getComputedStyle(layer).pointerEvents === 'none');
    test('finds structural surfaces', api.status().surfaceCount >= 3);
    test('main layout is transparent', getComputedStyle(document.getElementById('main')).backgroundColor === 'rgba(0, 0, 0, 0)');
    test('code block retains background', getComputedStyle(code).backgroundColor === codeBG);
    test('dialog message retains background', getComputedStyle(dialog).backgroundColor === dialogBG);
    test('clamps image position', layer.firstChild.style.backgroundPosition === '0% 100%');
    test('clamps veil opacity', Number(layer.lastChild.style.backgroundColor.match(/[\d.]+/g).at(-1)) === 0.85);
    test('clamps negative blur', layer.firstChild.style.filter === 'none');
    const beforeInvalid = document.documentElement.outerHTML;
    let invalidThrew = false;
    try { api.apply({imageData: 'https://example.com/private.png'}); } catch (_) { invalidThrew = true; }
    test('rejects remote images without changing DOM', invalidThrew && beforeInvalid === document.documentElement.outerHTML);
    let wrongSignatureThrew = false;
    try { api.apply({imageData: 'data:image/png;base64,SGVsbG8gd29ybGQ='}); } catch (_) { wrongSignatureThrew = true; }
    test('rejects incorrect image signatures', wrongSignatureThrew && beforeInvalid === document.documentElement.outerHTML);
    let svgThrew = false;
    try { api.apply({imageData: 'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4='}); } catch (_) { svgThrew = true; }
    test('rejects SVG and active image formats', svgThrew);
    api.apply({imageData: fixtureImage, opacity: 0.5});
    api.apply({imageData: fixtureImage, opacity: 0.6});
    test('reapply owns exactly one style and layer', document.querySelectorAll('[data-chatgpt-backdrop-layer]').length === 1 && document.querySelectorAll('[data-chatgpt-backdrop-style]').length === 1);
    const requestedAlpha = 0.1866135817307692;
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: requestedAlpha}); await wait();
    test('outer page-sidebar layout remains transparent', alpha(document.getElementById('root')) === 0);
    test('actual sidebar gets the requested tint once', Math.abs(alpha(document.getElementById('sidebar')) - requestedAlpha) < 0.005);
    const bottomGapDiagnostic = {nativeGap: nativeBottomGap, activeGap: bottomGap()};
    test('bottom fixture reproduces the native four pixel inset before applying', Math.abs(nativeBottomGap - 4) < 0.5);
    test('panel tint reaches the bottom of the page frame', Math.abs(bottomGap()) < 0.5 && Math.abs(alpha(bottomSidebar) - requestedAlpha) < 0.005);
    test('main pane also reaches the bottom without the native gutter', Math.abs(bottomFrame.getBoundingClientRect().bottom - bottomMain.getBoundingClientRect().bottom) < 0.5);
    test('bottom fix preserves the native top offset, inline inset and corner radius', Math.abs(bottomSidebar.getBoundingClientRect().top - nativeBottomTop) < 0.5 && getComputedStyle(bottomFrame).paddingInlineEnd === nativeBottomInlineInset && getComputedStyle(bottomMain).borderRadius === nativeBottomRadius);
    const bottomBox = bottomSidebar.getBoundingClientRect();
    const bottomHit = document.elementFromPoint(bottomBox.left + bottomBox.width / 2, bottomFrame.getBoundingClientRect().bottom - 0.5);
    test('last pixel of the page frame belongs to the panel or its controls', bottomHit === bottomSidebar || bottomSidebar.contains(bottomHit));
    bottomControl.click();
    test('bottom control retains its interaction and inner footer padding', bottomControlClicks === 1 && getComputedStyle(bottomControl).pointerEvents === 'auto' && Math.abs(bottomSidebar.getBoundingClientRect().bottom - bottomControl.getBoundingClientRect().bottom - 4) < 0.5);
    bottomFrame.style.height = '220px'; bottomFrame.style.width = '400px'; bottomSidebar.style.width = '180px';
    bottomFrame.style.setProperty('--spacing', '8px'); await wait();
    bottomGapDiagnostic.resizedGap = bottomGap();
    test('bottom coverage survives window, sidebar and spacing changes', Math.abs(bottomGap()) < 0.5 && Math.abs(bottomSidebar.getBoundingClientRect().width - 180) < 0.5 && getComputedStyle(bottomFrame).paddingInlineEnd === '8px');
    bottomFrame.setAttribute('data-app-shell-page-sidebar', 'false'); bottomSidebar.style.width = '52px'; await wait();
    test('rail-only collapsed sidebar still reaches the bottom', Math.abs(bottomGap()) < 0.5 && Math.abs(bottomSidebar.getBoundingClientRect().width - 52) < 0.5);
    bottomFrame.setAttribute('data-app-shell-page-sidebar', 'true');
    bottomFrame.setAttribute('data-app-shell-page-surface', 'false'); await wait();
    test('non-page layout retains its native bottom padding', Math.abs(bottomGap() - 8) < 0.5);
    bottomFrame.setAttribute('data-app-shell-page-surface', 'true');
    bottomFrame.setAttribute('role', 'dialog'); await wait();
    test('protected dialog layout retains its native bottom padding', Math.abs(bottomGap() - 8) < 0.5);
    bottomFrame.removeAttribute('role');
    if (bottomFrameStyle === null) bottomFrame.removeAttribute('style'); else bottomFrame.setAttribute('style', bottomFrameStyle);
    if (bottomSidebarStyle === null) bottomSidebar.removeAttribute('style'); else bottomSidebar.setAttribute('style', bottomSidebarStyle);
    await wait();
    const capStyle = () => getComputedStyle(nativeSidebar, '::before');
    const capRect = () => {
      const box = nativeSidebar.getBoundingClientRect();
      const cap = capStyle();
      const left = box.left + parseFloat(cap.left);
      const top = box.top + parseFloat(cap.top);
      return {left, top, right: left + parseFloat(cap.width), width: parseFloat(cap.width), height: parseFloat(cap.height)};
    };
    const finiteCapRect = () => Object.fromEntries(Object.entries(capRect()).map(([key, value]) => [key, Number.isFinite(value) ? value : null]));
    const titlebarCapDiagnostic = {
      initial: finiteCapRect(),
      background: capStyle().backgroundColor,
      sidebarDocumentTopBeforeApply: nativeSidebarDocumentTop,
      sidebarDocumentTopAfterApply: nativeSidebar.getBoundingClientRect().top + scrollY
    };
    test('titlebar cap uses the requested panel opacity', Math.abs(alpha(nativeSidebar, '::before') - requestedAlpha) < 0.005);
    test('titlebar cap is a generated non-interactive background', capStyle().content !== 'none' && capStyle().content !== 'normal' && capStyle().position === 'absolute' && capStyle().pointerEvents === 'none');
    test('titlebar cap covers the native 44 pixel top gap', Math.abs(capRect().top - nativeFrame.getBoundingClientRect().top) < 0.5 && Math.abs(capRect().height - 44) < 0.5);
    test('titlebar cap aligns with the sidebar including its navigation rail', Math.abs(capRect().left) < 0.5 && Math.abs(capRect().right - nativeSidebar.getBoundingClientRect().right) < 0.5 && getComputedStyle(document.getElementById('navigation-rail')).width === '52px');
    test('titlebar cap does not move the sidebar content', Math.abs(nativeSidebar.getBoundingClientRect().top + scrollY - nativeSidebarDocumentTop) < 0.5 && Math.abs(nativeSidebar.getBoundingClientRect().width - nativeSidebarRect.width) < 0.5);
    const controlBox = titlebarControl.getBoundingClientRect();
    const controlHit = document.elementFromPoint(controlBox.left + controlBox.width / 2, controlBox.top + controlBox.height / 2);
    test('titlebar cap leaves native controls reachable by pointer hit testing', controlHit === titlebarControl || titlebarControl.contains(controlHit));
    titlebarControl.click();
    test('titlebar control click handler remains functional', titlebarControlClicks === 1 && getComputedStyle(titlebarControl).pointerEvents === titlebarControlPointer && Math.abs(controlBox.top - titlebarControlRect.top) < 0.5);
    nativeSidebar.style.width = '240px'; await wait();
    test('titlebar cap follows sidebar resizing without horizontal overflow', Math.abs(capRect().width - 240) < 0.5 && Math.abs(capRect().right - nativeSidebar.getBoundingClientRect().right) < 0.5);
    nativeSidebar.style.width = '52px'; await wait();
    test('collapsed sidebar retains only the rail-width titlebar tint', Math.abs(capRect().width - 52) < 0.5 && getComputedStyle(nativeSidebar).display !== 'none');
    nativeSidebar.style.width = '0px'; await wait();
    test('zero-width sidebar leaves no painted titlebar extension', capRect().width === 0);
    nativeSidebar.style.display = 'none'; await wait();
    test('hidden sidebar leaves no visible titlebar cap', nativeSidebar.getClientRects().length === 0);
    if (nativeSidebarStyle === null) nativeSidebar.removeAttribute('style'); else nativeSidebar.setAttribute('style', nativeSidebarStyle);
    nativeFrame.style.setProperty('--height-titlebar', '52px'); await wait();
    titlebarCapDiagnostic.heightTokenChange = {
      cap: finiteCapRect(),
      frameTop: nativeFrame.getBoundingClientRect().top,
      frameLeft: nativeFrame.getBoundingClientRect().left,
      scrollY,
      heightToken: getComputedStyle(nativeFrame).getPropertyValue('--height-titlebar'),
      resolvedHeight: getComputedStyle(nativeSidebar).getPropertyValue('--app-shell-titlebar-height')
    };
    test('titlebar cap follows changes to the native titlebar height token', Math.abs(capRect().height - 52) < 0.5 && Math.abs(capRect().top - nativeFrame.getBoundingClientRect().top) < 0.5);
    if (nativeFrameStyle === null) nativeFrame.removeAttribute('style'); else nativeFrame.setAttribute('style', nativeFrameStyle);
    nativeFrame.setAttribute('data-app-shell-page-surface', 'false'); await wait();
    test('non-page-surface layout does not create the upward cap', capStyle().content === 'none' || capStyle().content === 'normal');
    nativeFrame.setAttribute('data-app-shell-page-surface', 'true'); await wait();
    test('peeking sidebar does not receive an upward titlebar cap', ['none', 'normal'].includes(getComputedStyle(document.getElementById('peeking-sidebar'), '::before').content));
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: 0});
    test('zero panel opacity clears both sidebar and titlebar cap', alpha(nativeSidebar) === 0 && alpha(nativeSidebar, '::before') === 0);
    test('zero panel opacity remains transparent through the bottom edge', alpha(bottomSidebar) === 0 && Math.abs(bottomGap()) < 0.5);
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: 1});
    test('full panel opacity applies equally to sidebar and titlebar cap', alpha(nativeSidebar) === 1 && alpha(nativeSidebar, '::before') === 1);
    test('full panel opacity covers the bottom edge without another paint layer', alpha(bottomSidebar) === 1 && Math.abs(bottomGap()) < 0.5);
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: requestedAlpha}); await wait();
    test('native sidebar extension reproduces a 20 CSS pixel band', getComputedStyle(nativeSidebar, '::after').width === '20px');
    test('native sidebar extension no longer inherits panel tint', alpha(nativeSidebar, '::after') === 0);
    test('native sidebar extension contains no background image', getComputedStyle(nativeSidebar, '::after').backgroundImage === 'none');
    test('native sidebar extension stays non-interactive', getComputedStyle(nativeSidebar, '::after').pointerEvents === 'none');
    test('native sidebar extension geometry and generated content are retained', getComputedStyle(nativeSidebar, '::after').content === originalAfterContent && getComputedStyle(nativeSidebar, '::after').width === '20px');
    test('content-surface sidebar pseudo decoration is preserved', getComputedStyle(contentSidebar, '::after').backgroundImage === contentPseudoImage && contentPseudoImage !== 'none');
    test('native main content visual hairline is transparent', getComputedStyle(document.getElementById('main')).borderLeftColor === 'rgba(0, 0, 0, 0)');
    test('native main content hairline geometry is preserved', getComputedStyle(document.getElementById('main')).borderLeftWidth === nativeMainBorderWidth && parseFloat(nativeMainBorderWidth) > 0);
    test('matching native border inside a dialog is preserved', getComputedStyle(document.getElementById('dialog-left-border')).borderLeftColor === dialogBorderColor);
    test('native resize hit area and translation are preserved', getComputedStyle(resizeWrapper).width === nativeResize.width && nativeResize.width === '16px' && getComputedStyle(resizeWrapper).transform === nativeResize.transform);
    test('native resize cursor and touch behavior are preserved', getComputedStyle(resizeHandle).cursor === nativeResize.cursor && nativeResize.cursor === 'col-resize' && getComputedStyle(resizeHandle).touchAction === nativeResize.touchAction);
    test('native resize pointer interaction remains enabled', getComputedStyle(resizeHandle).pointerEvents === nativeResize.pointerEvents && nativeResize.pointerEvents === 'auto');
    test('functional resize line paint is preserved', getComputedStyle(resizeLine).width === nativeResize.lineWidth && nativeResize.lineWidth === '1px' && getComputedStyle(resizeLine).backgroundColor === nativeResize.lineColor);
    test('functional resize pseudo hit area keeps native transparent paint', getComputedStyle(resizeHandle, '::after').backgroundColor === nativeResize.pseudoBackground);
    const sidebarDiagnostic = {
      sidebarAlpha: alpha(nativeSidebar),
      extensionWidth: getComputedStyle(nativeSidebar, '::after').width,
      extensionBackground: getComputedStyle(nativeSidebar, '::after').backgroundColor,
      extensionImage: getComputedStyle(nativeSidebar, '::after').backgroundImage,
      extensionPointerEvents: getComputedStyle(nativeSidebar, '::after').pointerEvents,
      mainBorderColor: getComputedStyle(document.getElementById('main')).borderLeftColor,
      resizeWidth: getComputedStyle(resizeWrapper).width,
      resizeCursor: getComputedStyle(resizeHandle).cursor
    };
    test('nested sidebar header does not add another tint', alpha(document.getElementById('sidebar-header')) === 0);
    test('native sidebar navigation does not add a 65 percent tint', alpha(document.getElementById('sidebar-navigation')) === 0);
    test('header decorative gradient is removed', decorationAbsent(document.getElementById('header-fade')));
    test('empty native page shadow layer is cleared', getComputedStyle(document.getElementById('page-shadow')).boxShadow === 'none');
    test('matching page layer with controls keeps its shadow', getComputedStyle(pageWithControls).boxShadow === pageControlShadow);
    test('footer solid decorative backing is removed', decorationAbsent(document.getElementById('footer-surface')));
    test('footer gradient decorative backing is removed', decorationAbsent(document.getElementById('footer-fade')));
    test('combined footer decorative backing is removed', decorationAbsent(document.getElementById('footer-combined')));
    test('matching footer decoration with controls is preserved', !decorationAbsent(document.getElementById('footer-with-controls')) && getComputedStyle(document.querySelector('#footer-with-controls button')).visibility === 'visible');
    test('composer controls and wrapper remain visible', getComputedStyle(document.getElementById('thread-footer')).display !== 'none' && getComputedStyle(document.getElementById('composer-control')).visibility === 'visible' && getComputedStyle(document.getElementById('composer-control')).display !== 'none');
    test('thread composer respects requested panel opacity', Math.abs(alpha(document.getElementById('thread-composer')) - requestedAlpha) < 0.005);
    test('thread composer drops only its native broad shadow', getComputedStyle(document.getElementById('thread-composer')).boxShadow === 'none');
    const variantComposer = document.getElementById('thread-composer');
    variantComposer.setAttribute('data-composer-surface-variant', 'opaque');
    test('opaque normal composer respects panel opacity', Math.abs(alpha(variantComposer) - requestedAlpha) < 0.005);
    variantComposer.setAttribute('data-composer-surface-variant', 'secondary');
    test('secondary normal composer respects panel opacity', Math.abs(alpha(variantComposer) - requestedAlpha) < 0.005);
    variantComposer.setAttribute('data-composer-surface-variant', 'default');
    test('editor does not add a second panel tint', alpha(document.getElementById('prompt-textarea')) === 0);
    test('home composer paints its body at requested opacity', Math.abs(alpha(document.getElementById('home-composer-body')) - requestedAlpha) < 0.005);
    test('home composer outer root does not add another tint', alpha(document.getElementById('home-composer')) === 0);
    test('home composer drops only its native broad shadow', getComputedStyle(document.getElementById('home-composer-body')).boxShadow === 'none');
    const typingComposer = document.getElementById('thread-composer');
    typingComposer.setAttribute('data-composer-layout', 'multiline');
    const typingBody = document.getElementById('composer-body');
    typingBody.setAttribute('data-composer-layout', 'multiline');
    typingBody.style.height = '240px';
    const editor = document.getElementById('prompt-textarea'); editor.focus();
    editor.append(document.createTextNode('\nA second line\nA third line\nA fourth line'));
    editor.dispatchEvent(new Event('input', {bubbles: true}));
    document.getElementById('thread-scroll').style.setProperty('--thread-footer-background-offset', '180px'); await wait();
    test('typing multiline text does not increase panel opacity', Math.abs(alpha(typingComposer) - requestedAlpha) < 0.005);
    test('typing multiline text does not restore footer backing', decorationAbsent(document.getElementById('footer-surface')) && decorationAbsent(document.getElementById('footer-fade')));
    test('typing preserves a transparent editor surface', alpha(editor) === 0);
    editor.blur(); typingComposer.replaceWith(originalComposer);
    document.getElementById('thread-scroll').setAttribute('style', '--thread-footer-background-offset:0px'); await wait();
    test('unrelated content gradient is preserved', getComputedStyle(unrelated).backgroundImage === unrelatedImage);
    test('unrelated content shadow is preserved', getComputedStyle(unrelated).boxShadow === unrelatedShadow);
    test('code block shadow is preserved', getComputedStyle(code).boxShadow === codeShadow);
    test('native menu background and shadow are preserved', getComputedStyle(nativeMenu).backgroundColor === menuBG && getComputedStyle(nativeMenu).boxShadow === menuShadow);
    test('decorative gradient inside a dialog is preserved', getComputedStyle(dialogDecoration).backgroundImage === dialogDecorationImage && !decorationAbsent(dialogDecoration));
    test('document composer keeps its transparent native surface', alpha(document.getElementById('document-composer')) === 0);
    test('inline composer keeps its transparent native surface', alpha(document.getElementById('inline-composer')) === 0);
    const documentEditor = document.querySelector('#document-composer [contenteditable]');
    documentEditor.focus(); await wait();
    const focusDiagnostic = {
      editorFocused: document.activeElement === documentEditor,
      activeTag: document.activeElement?.tagName,
      activeId: document.activeElement?.id,
      composerFocusWithin: document.getElementById('document-composer').matches(':focus-within'),
      background: getComputedStyle(document.getElementById('document-composer')).backgroundColor,
      surfaceToken: getComputedStyle(document.getElementById('document-composer')).getPropertyValue('--composer-layout-surface-background')
    };
    test('document editor receives real DOM and CSS focus', focusDiagnostic.editorFocused && focusDiagnostic.composerFocusWithin);
    test('document composer preserves its native focused surface', getComputedStyle(document.getElementById('document-composer')).backgroundColor === 'rgb(40, 40, 43)');
    documentEditor.blur();
    document.documentElement.className = 'light'; await wait();
    test('follows native light theme', api.status().mode === 'light');
    document.documentElement.className = 'dark'; await wait();
    test('follows native dark theme', api.status().mode === 'dark');
    const old = document.getElementById('main');
    const replacement = document.createElement('main');
    replacement.id = 'replacement'; replacement.innerHTML = '<p>New SPA route</p>';
    old.replaceWith(replacement); await wait();
    test('SPA replacement becomes transparent', getComputedStyle(replacement).backgroundColor === 'rgba(0, 0, 0, 0)');
    test('detached original surfaces restore their own markers', old.getAttribute('data-chatgpt-backdrop-surface') === 'prior-main');
    document.querySelector('[data-chatgpt-backdrop-layer]').remove(); await wait();
    test('recreates removed owned layer', document.querySelectorAll('[data-chatgpt-backdrop-layer]').length === 1);
    replacement.replaceWith(old); await wait();
    // These styles belong to the fixture's geometry exercises, not the engine.
    // Reset their exact original attribute state before testing engine cleanup.
    if (nativeSidebarStyle === null) nativeSidebar.removeAttribute('style'); else nativeSidebar.setAttribute('style', nativeSidebarStyle);
    if (nativeFrameStyle === null) nativeFrame.removeAttribute('style'); else nativeFrame.setAttribute('style', nativeFrameStyle);
    if (bottomFrameStyle === null) bottomFrame.removeAttribute('style'); else bottomFrame.setAttribute('style', bottomFrameStyle);
    if (bottomSidebarStyle === null) bottomSidebar.removeAttribute('style'); else bottomSidebar.setAttribute('style', bottomSidebarStyle);
    api.restore();
    const restoredHTML = document.documentElement.outerHTML;
    let restoreDifferenceIndex = 0;
    while (restoreDifferenceIndex < Math.min(baseline.length, restoredHTML.length) && baseline[restoreDifferenceIndex] === restoredHTML[restoreDifferenceIndex]) restoreDifferenceIndex++;
    const restoreDiagnostic = {
      exact: restoredHTML === baseline,
      firstDifferenceIndex: restoreDifferenceIndex,
      beforeContext: baseline.slice(Math.max(0, restoreDifferenceIndex - 180), restoreDifferenceIndex + 220),
      afterContext: restoredHTML.slice(Math.max(0, restoreDifferenceIndex - 180), restoreDifferenceIndex + 220),
      beforeHTML: restoredHTML === baseline ? null : baseline,
      afterHTML: restoredHTML === baseline ? null : restoredHTML
    };
    test('restores exact original document', restoredHTML === baseline);
    test('restores pre-existing marker attributes', document.documentElement.getAttribute('data-chatgpt-backdrop') === 'prior-root' && old.getAttribute('data-chatgpt-backdrop-surface') === 'prior-main');
    test('restore is repeatable', api.restore().restored === true);
    const restoredDocument = document.documentElement.outerHTML;
    const added = document.createElement('main'); document.body.append(added); await wait();
    test('restore disconnects automatic DOM styling', !added.hasAttribute('data-chatgpt-backdrop-surface') && !document.querySelector('[data-chatgpt-backdrop-layer]'));
    added.remove();
    test('no pending cleanup mutations remain', document.documentElement.outerHTML === restoredDocument);
    let gif87Accepted = false;
    try { gif87Accepted = api.apply({imageData: fixtureGIF87, opacity: 0, panelOpacity: 0}).active; } catch (_) {}
    test('accepts the GIF87a signature', gif87Accepted);
    let gifSupported = false;
    try { gifSupported = api.apply({imageData: fixtureGIF, opacity: 0, panelOpacity: 0}).active; } catch (_) {}
    test('accepts the GIF89a signature', gifSupported);
    const gifDiagnostic = {gif87Accepted, gifSupported};
    if (gifSupported) {
      const gifLayer = document.querySelector('[data-chatgpt-backdrop-layer]');
      const gifImage = gifLayer.firstElementChild;
      const gifURL = gifImage.style.backgroundImage;
      test('preserves the animated GIF data URL byte for byte', gifURL.includes(fixtureGIF));
      const beforeBadGIF = document.documentElement.outerHTML;
      let badGIFThrew = false;
      try { api.apply({imageData: 'data:image/gif;base64,SGVsbG8gd29ybGQ='}); } catch (_) { badGIFThrew = true; }
      test('rejects a false GIF signature without altering the active image', badGIFThrew && document.documentElement.outerHTML === beforeBadGIF);
      let wrongGIFMimeThrew = false;
      try { api.apply({imageData: fixtureImage.replace('image/png', 'image/gif')}); } catch (_) { wrongGIFMimeThrew = true; }
      test('rejects non-GIF bytes labeled as GIF', wrongGIFMimeThrew);
      const nativeStyle = gifImage.style;
      let backgroundURLWrites = 0;
      const styleProxy = new Proxy(nativeStyle, {
        get(target, key) { const value = Reflect.get(target, key, target); return typeof value === 'function' ? value.bind(target) : value; },
        set(target, key, value) { if (key === 'backgroundImage') backgroundURLWrites++; return Reflect.set(target, key, value, target); }
      });
      Object.defineProperty(gifImage, 'style', {configurable: true, get: () => styleProxy});
      try {
        api.apply({imageData: fixtureGIF, opacity: 0.2, blur: 4, panelOpacity: 0.3, position: {x: 25, y: 75}});
        test('GIF control changes reuse the same layer and image element', document.querySelector('[data-chatgpt-backdrop-layer]') === gifLayer && gifLayer.firstElementChild === gifImage);
        test('GIF control changes preserve the existing CSS image URL', gifImage.style.backgroundImage === gifURL);
        test('GIF control changes do not reassign backgroundImage', backgroundURLWrites === 0);
        document.documentElement.className = 'light'; await wait();
        document.documentElement.className = 'dark'; await wait();
        test('native mode changes keep the GIF image and timeline assignment', gifLayer.firstElementChild === gifImage && gifImage.style.backgroundImage === gifURL && backgroundURLWrites === 0);
        api.apply({imageData: fixtureImage, opacity: 0});
        test('choosing a different image updates its URL without replacing the layer', backgroundURLWrites === 1 && gifImage.style.backgroundImage.includes(fixtureImage) && document.querySelector('[data-chatgpt-backdrop-layer]') === gifLayer);
      } finally { delete gifImage.style; }
      gifDiagnostic.backgroundURLWritesAfterControlChangesAndImageSwap = backgroundURLWrites;
      api.restore();
      test('GIF restoration removes owned layers and exactly restores the document', document.documentElement.outerHTML === restoredDocument);
      // Leave a plain full-viewport GIF behind the hidden local fixture for
      // native WebKit snapshots; no production or external page is involved.
      api.apply({imageData: fixtureGIF, opacity: 0, blur: 0, panelOpacity: 0});
      document.getElementById('root').style.visibility = 'hidden';
      scrollTo(0, 0); await wait();
    }
    return {engineVersion: api.version, passed: checks.filter(check => check.pass).length, total: checks.length, settleTimeouts, focusDiagnostic, sidebarDiagnostic, titlebarCapDiagnostic, bottomGapDiagnostic, restoreDiagnostic, gifDiagnostic, gifSupported, checks};
    """#
}
