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
        /* Native work-mode paint roots: the fixed environment pill, attached
           utility rail, and styled summary island each own one surface fill. */
        #work-surface-fixture{position:absolute;left:720px;top:280px;width:300px}
        .bg-surface-elevated-secondary{background-color:rgb(44,44,44)}
        .bg-background-composer-action-bar{background-color:rgb(38,38,38)}
        #work-surface-fixture button{background:transparent;color:inherit;pointer-events:auto}
        [data-in-progress-fixed-content] .bg-surface-elevated-secondary{border:1px solid rgba(255,255,255,.12);border-radius:24px;padding:6px 12px}
        [data-composer-utility-rail]{min-height:32px}
        [data-summary-panel-variant].bg-surface-elevated-secondary{border-radius:20px;box-shadow:0 0 0 .5px rgba(255,255,255,.12),0 16px 48px rgba(0,0,0,.6)}
        [data-summary-panel-variant] header.sticky{position:sticky;top:8px;height:28px}
        [data-summary-panel-variant] header.sticky::before{content:"";position:absolute;left:0;right:0;top:-8px;height:8px;background-color:rgb(44,44,44);pointer-events:none}
        .fixture-summary-item-state{background-color:rgba(255,255,255,.08)}
        .fixture-summary-thumbnail{display:inline-block;width:16px;height:16px;background-color:rgb(102,142,182)}
        /* Dots embeds its own messaging shell inside main.thread-pane. The
           inner shell and div.thread-pane each paint independently of main. */
        :root{--color-background-primary:rgb(24,24,24)}
        :root.light{--color-background-primary:rgb(250,250,250)}
        .messaging-root{background:var(--color-background-primary)}
        .messaging-embedded{display:flex;flex-direction:column;width:100%;min-width:0;height:100%;min-height:0;position:relative}
        :where(.messaging-root) .thread-pane{background:var(--color-background-primary);display:flex;flex-direction:column;min-width:0;min-height:0;position:relative;container-type:inline-size}
        .thread-pane.flex-1{flex:1}
        #dots-page{position:absolute;left:600px;top:140px;width:400px;height:300px}
        #dots-outer-pane{flex:1}
        .conversation-viewport{display:flex;flex:1;min-height:0}
        .messages-scroll{flex:1;overflow-y:auto;min-height:0}
        .message-list{min-height:420px}
        .message-row.self .message-bubble{background:rgb(113,146,184);border-radius:18px;padding:8px}
        .dots-reaction,.dots-attachment{background:var(--color-background-primary);border:1px solid rgb(90,90,90)}
        .conversation-footer{z-index:2;pointer-events:none;inset-inline:0;position:absolute;bottom:0}
        .composer-wrap{pointer-events:auto;flex-shrink:0}
        .composer-wrap:not([data-has-composer-surface]){border-bottom:12px solid var(--color-background-primary)}
        .composer-disclaimer{background:var(--color-background-primary);padding:6px 12px 0}
        .typing-indicator:not(:empty){background:var(--color-background-primary);padding-block:12px}
        #dots-footer ._background_fixture{position:absolute;inset:0;pointer-events:none}
        #dots-disclaimer-above{position:relative}
        #standalone-messaging,#dots-attachments-viewer{display:none}
        /* Dots portals its profile header and a separate 24-spacing-unit
           floating fade into the app layout, outside the messaging subtree. */
        #dots-header-host{--spacing:4px;--color-surface:rgb(24,24,27);position:fixed;left:250px;top:44px;width:200px;height:100px}
        #dots-header-host .contents{display:contents}
        ._floatingHeader_fixture{position:absolute;left:0;top:0;z-index:20;width:100%;height:calc(var(--spacing,4px) * 24);pointer-events:none;background-image:linear-gradient(to bottom,var(--color-surface,rgb(24,24,27)),transparent)}
        [data-app-shell-page-surface=true] ._floatingHeader_fixture{background-image:linear-gradient(to bottom,var(--color-background-primary),color-mix(in srgb,var(--color-background-primary) 82%,transparent) 10%,color-mix(in srgb,var(--color-background-primary) 48%,transparent) 30%,color-mix(in srgb,var(--color-background-primary) 12%,transparent) 60%,transparent)}
        #dots-header-profile{position:absolute;left:0;top:0;height:28px;z-index:21;pointer-events:auto}
        #dots-header-action{position:absolute;right:4px;top:0;width:40px;height:28px;z-index:21;pointer-events:auto;background:rgb(55,56,57)}
        #dots-header-anchor{position:absolute;left:0;top:0;width:200px;height:40px;pointer-events:none}
        #dots-header-negative-cases,#dots-header-unscoped{display:none}
        </style>
        <script>
        \(engine)
        window.fixtureImage = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/mZQAAAAASUVORK5CYII=';
        window.fixtureGIF87 = 'data:image/gif;base64,\(Self.animatedGIFBase64)';
        window.fixtureGIF = 'data:image/gif;base64,' + btoa('GIF89a' + atob('\(Self.animatedGIFBase64)').slice(6));
        window.titlebarControlClicks = 0;
        window.bottomControlClicks = 0;
        window.workControlClicks = 0;
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
            <div id="work-surface-fixture">
              <div id="environment-actions" data-in-progress-fixed-content class="group/environment-actions">
                <div class="flex w-full max-w-(--thread-content-max-width) min-w-0 justify-center"><div class="relative z-10 w-fit max-w-full min-w-0 overflow-hidden rounded-3xl"><div id="environment-pill" class="flex w-max max-w-full min-w-0 items-center gap-2 rounded-3xl border border-border/80 bg-surface-elevated-secondary px-3 py-1.5 text-default"><button id="environment-control" type="button" onclick="workControlClicks++">Edit environment</button></div></div></div>
              </div>
              <section id="work-home-composer" class="_ComposerLayoutRoot_fixture" data-composer-surface-variant="default" data-composer-utility-bar-variant="home"><div id="work-utility-wrapper" data-composer-rail data-composer-rail-placement="above" class="_rail_fixture _attached_fixture relative flex min-w-0 flex-col empty:contents border-border/80"><div id="work-utility-rail" data-composer-utility-rail data-composer-rail-item="present" data-composer-rail-placement="above" data-composer-rail-contained class="_item_fixture relative min-w-0 overflow-clip text-default grid select-none px-1 bg-background-composer-action-bar"><div class="flex min-h-0 min-w-0 flex-col"><div class="min-w-0 shrink-0"><div data-composer-utility-bar-scroll-area><button id="project-control" type="button" onclick="workControlClicks++">Choose project</button><button id="computer-control" type="button" onclick="workControlClicks++">This computer</button></div></div></div></div></div><div id="work-home-body" class="_ComposerLayoutBody_fixture" data-composer-body>Work composer body</div></section>
              <section id="work-summary" data-summary-panel-variant="summary" data-summary-panel-density="comfortable" class="group/summary-panel relative flex max-h-full min-h-0 flex-col overflow-hidden isolate bg-surface-elevated-secondary electron:elevation-prominent"><header id="summary-header" class="sticky top-2 z-10 flex h-7 w-full min-w-0 items-center justify-start gap-2 pb-0.5 text-sm font-normal text-secondary bg-surface-elevated-secondary before:bg-surface-elevated-secondary"><button id="summary-control" type="button" aria-expanded="true" onclick="workControlClicks++">Outputs</button></header><div id="summary-body"><div id="summary-item" class="fixture-summary-item-state"><span id="summary-thumbnail" class="fixture-summary-thumbnail"></span>Subagents</div><div>Sources</div></div></section>
              <div id="floating-utility-rail" data-composer-utility-rail data-composer-rail-item="present" class="_item_fixture relative min-w-0">Already surfaced floating rail</div>
              <section id="unstyled-summary" data-summary-panel-variant="summary" class="group/summary-panel relative flex min-h-0 flex-col"><header id="unstyled-summary-header" class="sticky bg-surface-elevated-secondary before:bg-surface-elevated-secondary">Docked native header</header></section>
              <div id="work-variant-fixtures" hidden></div>
              <div id="protected-work-dialog" role="dialog" hidden></div><div id="protected-work-menu" role="menu" hidden></div>
            </div>
          </main>
          <section id="bottom-layout" class="bottom-layout-fixture" data-app-shell-frame data-app-shell-page-surface="true" data-app-shell-page-sidebar="true"><div id="bottom-workspace" data-app-shell-workspace-row><aside id="bottom-sidebar" class="app-shell-left-panel" data-app-shell-left-panel-appearance="translucent"><nav id="bottom-navigation"><button id="bottom-control" type="button" onclick="bottomControlClicks++">Bottom control</button></nav></aside><div id="bottom-main" data-app-shell-main-surface="default">Main pane</div></div></section>
          <div id="dots-page" class="messaging-root messaging-embedded"><main id="dots-outer-pane" class="thread-pane">
            <div id="dots-inner-root" class="messaging-root messaging-embedded" data-chatgpt-backdrop-surface="prior-dots"><div id="dots-inner-pane" class="thread-pane flex-1">
              <div class="conversation-viewport"><div id="dots-scroll" class="messages-scroll" data-role="messages-scroll"><div class="message-list">
                <div class="message-row self"><div id="dots-bubble" class="message-bubble">Native blue message</div></div>
                <button id="dots-reaction" class="dots-reaction" type="button">Reaction</button><div id="dots-attachment" class="dots-attachment">Attachment card</div>
              </div></div></div>
            </div></div>
            <div id="dots-footer" class="conversation-footer">
              <div id="dots-typing" class="typing-indicator">Typing indicator</div>
              <div id="dots-composer-wrap" class="composer-wrap">
                <div id="dots-disclaimer-above" class="composer-disclaimer-above"><div id="dots-footer-surface" class="_background_fixture _surface_fixture" aria-hidden="true"></div><div id="dots-footer-fade" class="_background_fixture _fade_fixture" aria-hidden="true"></div><span id="dots-legal">Native disclaimer text</span></div>
                <section id="dots-composer" class="_ComposerLayoutRoot_fixture" data-role="composer" data-codex-composer-root data-composer-surface-variant="default"><div id="dots-transcript-backdrop" class="_transcriptBackdrop_fixture"><div id="dots-footer-combined" class="_background_fixture _combined_fixture" aria-hidden="true"></div></div><div contenteditable="true" id="dots-editor">Dots message</div><button id="dots-send" type="button" onclick="window.dotsSendClicks=(window.dotsSendClicks||0)+1">Send</button></section>
              </div>
              <div id="dots-disclaimer" class="composer-disclaimer">Native footer text</div>
            </div>
          </main></div>
          <div id="standalone-messaging" class="messaging-root"><div class="thread-pane"><div class="conversation-footer"><div class="composer-wrap"><div class="composer-disclaimer-above"><div class="_background_fixture _surface_fixture" aria-hidden="true"></div></div></div></div></div></div>
          <div id="dots-attachments-viewer" class="messaging-root messaging-attachments"><div class="thread-pane">Attachment viewer</div></div>
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
                // Launch Services and accessibility clients may briefly take
                // focus while this standalone fixture is starting. Reclaim its
                // own key window before checking native CSS focus behavior.
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
                self?.window?.makeFirstResponder(webView)
                let nativeFocusBefore = ["applicationActive": NSApp.isActive,
                                         "keyWindow": self?.window?.isKeyWindow ?? false]
                let value = try await webView.callAsyncJavaScript(Self.assertions, arguments: [:], in: nil, contentWorld: .page)
                guard var object = value as? [String: Any],
                      var checks = object["checks"] as? [[String: Any]], let self else {
                    self?.finish(error: "WebKit returned an unexpected result: \(String(describing: value))")
                    return
                }
                object["nativeFocusBefore"] = nativeFocusBefore
                object["nativeFocusAfter"] = ["applicationActive": NSApp.isActive,
                                             "keyWindow": self.window?.isKeyWindow ?? false]
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
    test('early apply reveals the nested Dots messaging shell', ['dots-page', 'dots-outer-pane', 'dots-inner-root', 'dots-inner-pane'].every(id => getComputedStyle(document.getElementById(id)).backgroundColor === 'rgba(0, 0, 0, 0)'));
    api.restore();
    // Build native-equivalent variants before capturing the restoration
    // baseline. Hidden fixture hosts still expose real computed CSS styles.
    const cloneWorkSurface = (node, prefix, host) => {
      const copy = node.cloneNode(true);
      for (const child of [copy, ...copy.querySelectorAll('[id]')]) {
        if (child.id) child.id = prefix + child.id;
      }
      host.append(copy);
      return copy;
    };
    const dynamicSummary = cloneWorkSurface(document.getElementById('work-summary'), 'dynamic-', document.getElementById('work-variant-fixtures'));
    dynamicSummary.setAttribute('data-summary-panel-variant', 'dynamic-isle');
    for (const [prefix, hostID] of [['dialog-', 'protected-work-dialog'], ['menu-', 'protected-work-menu']]) {
      const host = document.getElementById(hostID);
      for (const id of ['environment-actions', 'work-utility-wrapper', 'work-summary']) cloneWorkSurface(document.getElementById(id), prefix, host);
    }
    const dotsHeaderHost = document.createElement('div');
    dotsHeaderHost.id = 'dots-header-host'; dotsHeaderHost.setAttribute('data-app-shell-main-content-layout', '');
    dotsHeaderHost.innerHTML = `
      <div class="invisible contents" style="visibility:visible">
        <div id="dots-header-portal-fade" class="pointer-events-none _floatingHeader_fixture" aria-hidden="true" style="position-anchor: --orbit-messaging-header-fixture"></div>
        <header id="dots-header-profile" class="_header_fixture">Dots profile</header>
        <button id="dots-header-action" type="button" onclick="window.dotsHeaderClicks=(window.dotsHeaderClicks||0)+1">More</button>
      </div>
      <div id="dots-header-anchor" aria-hidden="true" style="anchor-name: --orbit-messaging-header-fixture"></div>
      <div id="dots-header-negative-cases">
        <div id="dots-header-nonempty" class="_floatingHeader_fixture" aria-hidden="true" style="position-anchor: --orbit-messaging-header-fixture"><button type="button">Preserved controls</button></div>
        <div id="dots-header-other-anchor" class="_floatingHeader_fixture" aria-hidden="true" style="position-anchor: --unrelated-header-fixture"></div>
        <div id="dots-header-no-anchor" class="_floatingHeader_fixture" aria-hidden="true"></div>
        <div id="dots-header-not-hidden" class="_floatingHeader_fixture" style="position-anchor: --orbit-messaging-header-fixture"></div>
        <div role="dialog"><div id="dots-header-dialog" class="_floatingHeader_fixture" aria-hidden="true" style="position-anchor: --orbit-messaging-header-fixture"></div></div>
        <div role="menu"><div id="dots-header-menu" class="_floatingHeader_fixture" aria-hidden="true" style="position-anchor: --orbit-messaging-header-fixture"></div></div>
      </div>`;
    const dotsHeaderOutside = document.createElement('div');
    dotsHeaderOutside.id = 'dots-header-unscoped'; dotsHeaderOutside.className = '_floatingHeader_fixture'; dotsHeaderOutside.setAttribute('aria-hidden', 'true');
    dotsHeaderOutside.setAttribute('style', 'position-anchor: --orbit-messaging-header-fixture');
    document.getElementById('root').append(dotsHeaderHost, dotsHeaderOutside);
    const baseline = document.documentElement.outerHTML;
    const dotsHeaderFade = document.getElementById('dots-header-portal-fade');
    const dotsHeaderAction = document.getElementById('dots-header-action');
    const dotsHeaderAnchor = document.getElementById('dots-header-anchor');
    const dotsHeaderGeometry = node => {
      const style = getComputedStyle(node); const box = node.getBoundingClientRect();
      return {x: box.x, y: box.y, width: box.width, height: box.height, position: style.position, zIndex: style.zIndex, pointerEvents: style.pointerEvents, visibility: style.visibility};
    };
    const dotsHeaderNative = {fade: dotsHeaderGeometry(dotsHeaderFade), action: dotsHeaderGeometry(dotsHeaderAction), anchor: dotsHeaderGeometry(dotsHeaderAnchor), fadeImage: getComputedStyle(dotsHeaderFade).backgroundImage, actionBackground: getComputedStyle(dotsHeaderAction).backgroundColor, anchorStyle: dotsHeaderAnchor.getAttribute('style'), fadeStyle: dotsHeaderFade.getAttribute('style')};
    test('native portaled Dots header fade reproduces a 96 pixel gradient', dotsHeaderNative.fade.height === 96 && dotsHeaderNative.fadeImage.includes('linear-gradient'));
    const dotsPage = document.getElementById('dots-page');
    const dotsNativeClone = dotsPage.cloneNode(true);
    const dotsNodes = ['dots-page', 'dots-outer-pane', 'dots-inner-root', 'dots-inner-pane'].map(id => document.getElementById(id));
    const dotsBubble = document.getElementById('dots-bubble');
    const dotsReaction = document.getElementById('dots-reaction');
    const dotsAttachment = document.getElementById('dots-attachment');
    const dotsWrap = document.getElementById('dots-composer-wrap');
    const dotsWrapStyle = dotsWrap.getAttribute('style');
    const dotsScroll = document.getElementById('dots-scroll');
    const dotsNative = {
      rootBackground: getComputedStyle(dotsPage).backgroundColor,
      bubble: getComputedStyle(dotsBubble).backgroundColor,
      reaction: getComputedStyle(dotsReaction).backgroundColor,
      attachment: getComputedStyle(dotsAttachment).backgroundColor,
      borderWidth: getComputedStyle(dotsWrap).borderBottomWidth,
      wrapPointer: getComputedStyle(dotsWrap).pointerEvents,
      footerPointer: getComputedStyle(document.getElementById('dots-footer')).pointerEvents,
      scrollOverflow: getComputedStyle(dotsScroll).overflowY,
      scrollHeight: dotsScroll.scrollHeight,
      scrollClientHeight: dotsScroll.clientHeight
    };
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
    const workPanelIDs = ['environment-pill', 'work-utility-rail', 'work-summary'];
    const workPanels = workPanelIDs.map(id => document.getElementById(id));
    const workHeader = document.getElementById('summary-header');
    const workControlIDs = ['environment-control', 'project-control', 'computer-control', 'summary-control'];
    const workControls = workControlIDs.map(id => document.getElementById(id));
    const workNative = {
      borders: workPanels.map(node => getComputedStyle(node).borderTopWidth),
      radii: workPanels.map(node => getComputedStyle(node).borderRadius),
      sizes: workPanels.map(node => ({width: node.getBoundingClientRect().width, height: node.getBoundingClientRect().height})),
      itemBackground: getComputedStyle(document.getElementById('summary-item')).backgroundColor,
      thumbnailBackground: getComputedStyle(document.getElementById('summary-thumbnail')).backgroundColor,
      unstyledHeaderBackground: getComputedStyle(document.getElementById('unstyled-summary-header')).backgroundColor,
      unstyledHeaderBefore: getComputedStyle(document.getElementById('unstyled-summary-header'), '::before').backgroundColor,
      protectedPaint: ['dialog-', 'menu-'].flatMap(prefix => [...workPanelIDs, 'summary-header'].map(id => {
        const node = document.getElementById(prefix + id);
        return {id: prefix + id, background: getComputedStyle(node).backgroundColor, shadow: getComputedStyle(node).boxShadow, before: getComputedStyle(node, '::before').backgroundColor};
      }))
    };
    test('work surface fixtures reproduce the three opaque native fills', workPanels.every(node => alpha(node) === 1));
    test('summary fixture reproduces separate opaque sticky header and cap fills', alpha(workHeader) === 1 && alpha(workHeader, '::before') === 1);
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
    test('portaled Dots header fade outside the messaging subtree no longer paints', !dotsPage.contains(dotsHeaderFade) && decorationAbsent(dotsHeaderFade));
    test('Dots header fade retains native geometry and anchor metadata', JSON.stringify(dotsHeaderGeometry(dotsHeaderFade)) === JSON.stringify(dotsHeaderNative.fade) && dotsHeaderFade.getAttribute('style') === dotsHeaderNative.fadeStyle && dotsHeaderFade.getAttribute('aria-hidden') === 'true');
    test('portaled Dots profile and action controls keep their native appearance and geometry', JSON.stringify(dotsHeaderGeometry(dotsHeaderAction)) === JSON.stringify(dotsHeaderNative.action) && getComputedStyle(dotsHeaderAction).backgroundColor === dotsHeaderNative.actionBackground && getComputedStyle(document.getElementById('dots-header-profile')).visibility === 'visible');
    const dotsHeaderActionBox = dotsHeaderAction.getBoundingClientRect();
    test('portaled Dots action remains reachable by pointer hit testing', document.elementFromPoint(dotsHeaderActionBox.x + dotsHeaderActionBox.width / 2, dotsHeaderActionBox.y + dotsHeaderActionBox.height / 2) === dotsHeaderAction);
    dotsHeaderAction.click();
    test('portaled Dots action handler remains functional', window.dotsHeaderClicks === 1);
    test('Dots header anchor marker keeps its native size and style', JSON.stringify(dotsHeaderGeometry(dotsHeaderAnchor)) === JSON.stringify(dotsHeaderNative.anchor) && dotsHeaderAnchor.getAttribute('style') === dotsHeaderNative.anchorStyle);
    test('nonempty Dots header decoration with controls keeps its native gradient', getComputedStyle(document.getElementById('dots-header-nonempty')).backgroundImage === dotsHeaderNative.fadeImage && getComputedStyle(document.querySelector('#dots-header-nonempty button')).display !== 'none');
    test('unrelated header anchors unmarked layers and out-of-layout gradients are preserved', ['dots-header-other-anchor', 'dots-header-no-anchor', 'dots-header-not-hidden', 'dots-header-unscoped'].every(id => getComputedStyle(document.getElementById(id)).backgroundImage === dotsHeaderNative.fadeImage));
    test('matching Dots header gradients in protected dialogs and menus are preserved', ['dots-header-dialog', 'dots-header-menu'].every(id => getComputedStyle(document.getElementById(id)).backgroundImage === dotsHeaderNative.fadeImage));
    const dotsHeaderLayer = document.querySelector('[data-chatgpt-backdrop-layer]');
    const dotsHeaderImage = dotsHeaderLayer.firstElementChild;
    const dotsHeaderImageURL = dotsHeaderImage.style.backgroundImage;
    const dotsHeaderReplacement = dotsHeaderFade.cloneNode(true);
    dotsHeaderFade.replaceWith(dotsHeaderReplacement); await wait();
    test('a newly portaled Dots header fade is cleared after SPA mounting', decorationAbsent(dotsHeaderReplacement));
    test('Dots header portal replacement preserves the existing wallpaper layer and image assignment', document.querySelector('[data-chatgpt-backdrop-layer]') === dotsHeaderLayer && dotsHeaderLayer.firstElementChild === dotsHeaderImage && dotsHeaderImage.style.backgroundImage === dotsHeaderImageURL);
    dotsHeaderReplacement.replaceWith(dotsHeaderFade); await wait();
    const dotsHeaderDiagnostic = {native: dotsHeaderNative, activeImage: getComputedStyle(dotsHeaderFade).backgroundImage, activeGeometry: dotsHeaderGeometry(dotsHeaderFade)};
    for (const [index, name] of ['environment pill', 'attached work utility rail', 'summary island'].entries()) {
      test(name + ' follows requested panel opacity', Math.abs(alpha(workPanels[index]) - requestedAlpha) < 0.005);
    }
    test('work panel roots remove broad shadows and background images', workPanels.every(node => getComputedStyle(node).boxShadow === 'none' && getComputedStyle(node).backgroundImage === 'none'));
    test('environment pill wrappers stay transparent instead of doubling the tint', alpha(document.getElementById('environment-actions')) === 0 && [...document.getElementById('environment-pill').parentElement.parentElement.children].every(node => alpha(node) === 0));
    test('home work composer paints rail and body without a second outer tint', alpha(document.getElementById('work-home-composer')) === 0 && Math.abs(alpha(document.getElementById('work-home-body')) - requestedAlpha) < 0.005 && Math.abs(alpha(document.getElementById('work-utility-rail')) - requestedAlpha) < 0.005);
    test('attached utility rail children and outer wrapper add no second tint', alpha(document.getElementById('work-utility-wrapper')) === 0 && alpha(document.querySelector('#work-utility-rail [data-composer-utility-bar-scroll-area]')) === 0);
    test('summary sticky header and its upper cap add no second tint', alpha(workHeader) === 0 && alpha(workHeader, '::before') === 0 && getComputedStyle(workHeader).backgroundImage === 'none' && getComputedStyle(workHeader, '::before').backgroundImage === 'none');
    test('summary body stays transparent beneath native item states', alpha(document.getElementById('summary-body')) === 0);
    test('dynamic isle uses one tint and clears its nested sticky header paint', Math.abs(alpha(dynamicSummary) - requestedAlpha) < 0.005 && alpha(document.getElementById('dynamic-summary-header')) === 0 && alpha(document.getElementById('dynamic-summary-header'), '::before') === 0);
    test('floating utility rail without a native fill stays transparent', alpha(document.getElementById('floating-utility-rail')) === 0);
    test('unstyled docked summary retains its native header and cap fills', alpha(document.getElementById('unstyled-summary')) === 0 && getComputedStyle(document.getElementById('unstyled-summary-header')).backgroundColor === workNative.unstyledHeaderBackground && getComputedStyle(document.getElementById('unstyled-summary-header'), '::before').backgroundColor === workNative.unstyledHeaderBefore);
    test('work panels preserve native borders, radii and geometry', workPanels.every((node, index) => getComputedStyle(node).borderTopWidth === workNative.borders[index] && getComputedStyle(node).borderRadius === workNative.radii[index] && Math.abs(node.getBoundingClientRect().width - workNative.sizes[index].width) < 0.5 && Math.abs(node.getBoundingClientRect().height - workNative.sizes[index].height) < 0.5));
    test('summary item states and thumbnail colors remain native', getComputedStyle(document.getElementById('summary-item')).backgroundColor === workNative.itemBackground && getComputedStyle(document.getElementById('summary-thumbnail')).backgroundColor === workNative.thumbnailBackground);
    test('matching work surfaces inside dialogs and menus retain all native paint', workNative.protectedPaint.every(({id, background, shadow, before}) => {
      const node = document.getElementById(id);
      return getComputedStyle(node).backgroundColor === background && getComputedStyle(node).boxShadow === shadow && getComputedStyle(node, '::before').backgroundColor === before;
    }));
    workControls.forEach(node => node.click());
    test('environment, project, computer and summary controls remain interactive', workControlClicks === 4 && workControls.every(node => getComputedStyle(node).pointerEvents === 'auto' && getComputedStyle(node).visibility === 'visible') && document.getElementById('summary-control').getAttribute('aria-expanded') === 'true');
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: 0});
    test('zero opacity clears all work panel fills including sticky header cap', [...workPanels, dynamicSummary].every(node => alpha(node) === 0) && alpha(workHeader) === 0 && alpha(workHeader, '::before') === 0);
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: 1});
    test('full opacity fills each work panel once without repainting nested headers', [...workPanels, dynamicSummary].every(node => alpha(node) === 1) && alpha(workHeader) === 0 && alpha(workHeader, '::before') === 0);
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: requestedAlpha}); await wait();
    const workSurfaceDiagnostic = {requestedAlpha, backgrounds: workPanels.map(node => ({id: node.id, color: getComputedStyle(node).backgroundColor})), summaryHeader: getComputedStyle(workHeader).backgroundColor, summaryHeaderCap: getComputedStyle(workHeader, '::before').backgroundColor};
    test('Dots nested page surfaces all reveal the wallpaper', dotsNodes.every(node => alpha(node) === 0 && getComputedStyle(node).backgroundImage === 'none'));
    test('Dots shared footer surface, fade and transcript backing are removed', ['dots-footer-surface', 'dots-footer-fade', 'dots-footer-combined'].every(id => decorationAbsent(document.getElementById(id))));
    test('Dots footer wrappers and disclaimer text remain visible', ['dots-footer', 'dots-disclaimer-above', 'dots-transcript-backdrop', 'dots-legal', 'dots-disclaimer'].every(id => { const style = getComputedStyle(document.getElementById(id)); return style.display !== 'none' && style.visibility === 'visible' && Number(style.opacity) > 0; }));
    test('Dots disclaimer and nonempty typing indicator have transparent backing', alpha(document.getElementById('dots-disclaimer')) === 0 && alpha(document.getElementById('dots-typing')) === 0);
    test('Dots composer bottom inset loses only its paint', alpha(dotsWrap) === 0 && getComputedStyle(dotsWrap).borderBottomColor === 'rgba(0, 0, 0, 0)' && getComputedStyle(dotsWrap).borderBottomWidth === dotsNative.borderWidth && dotsNative.borderWidth === '12px');
    test('Dots composer follows the selected panel opacity once', Math.abs(alpha(document.getElementById('dots-composer')) - requestedAlpha) < 0.005 && alpha(document.getElementById('dots-editor')) === 0);
    test('Dots blue bubbles retain their native fill', getComputedStyle(dotsBubble).backgroundColor === dotsNative.bubble && dotsNative.bubble === 'rgb(113, 146, 184)');
    test('Dots reactions and attachments retain the native primary color', getComputedStyle(dotsReaction).backgroundColor === dotsNative.reaction && getComputedStyle(dotsAttachment).backgroundColor === dotsNative.attachment && dotsNative.reaction === dotsNative.rootBackground);
    test('Dots footer and composer keep their native pointer behavior', getComputedStyle(dotsWrap).pointerEvents === dotsNative.wrapPointer && dotsNative.wrapPointer === 'auto' && getComputedStyle(document.getElementById('dots-footer')).pointerEvents === dotsNative.footerPointer && dotsNative.footerPointer === 'none');
    dotsScroll.scrollTop = 64;
    test('Dots transcript retains native overflow, height and scrolling', getComputedStyle(dotsScroll).overflowY === dotsNative.scrollOverflow && dotsNative.scrollOverflow === 'auto' && dotsScroll.scrollTop === 64 && dotsScroll.scrollHeight === dotsNative.scrollHeight && dotsScroll.clientHeight === dotsNative.scrollClientHeight);
    dotsScroll.scrollTop = 0;
    const dotsSend = document.getElementById('dots-send');
    const dotsSendBox = dotsSend.getBoundingClientRect();
    const dotsSendHit = document.elementFromPoint(dotsSendBox.left + dotsSendBox.width / 2, dotsSendBox.top + dotsSendBox.height / 2);
    test('Dots composer send button remains reachable by pointer hit testing', dotsSendHit === dotsSend || dotsSend.contains(dotsSendHit));
    dotsSend.click();
    test('Dots composer send handler remains functional', window.dotsSendClicks === 1);
    const dotsEditor = document.getElementById('dots-editor'); dotsEditor.focus();
    test('Dots editor remains editable and receives focus', dotsEditor.isContentEditable && document.activeElement === dotsEditor);
    dotsEditor.blur();
    dotsWrap.setAttribute('data-has-composer-surface', '');
    dotsWrap.style.borderBottom = '7px solid rgb(81, 82, 83)';
    test('Dots alternate composer-surface variant retains its own bottom border', getComputedStyle(dotsWrap).borderBottomColor === 'rgb(81, 82, 83)' && getComputedStyle(dotsWrap).borderBottomWidth === '7px');
    dotsWrap.removeAttribute('data-has-composer-surface');
    if (dotsWrapStyle === null) dotsWrap.removeAttribute('style'); else dotsWrap.setAttribute('style', dotsWrapStyle);
    const dotsContentDecoration = document.createElement('div');
    dotsContentDecoration.className = '_background_fixture _fade_fixture'; dotsContentDecoration.setAttribute('aria-hidden', 'true'); dotsContentDecoration.innerHTML = '<button type="button">Retained control</button>';
    document.getElementById('dots-footer').append(dotsContentDecoration); await wait();
    test('Dots matching footer layer with controls is preserved', !decorationAbsent(dotsContentDecoration) && getComputedStyle(dotsContentDecoration.firstElementChild).visibility === 'visible');
    dotsContentDecoration.remove();
    test('standalone messaging and attachment-viewer page paint is preserved', ['standalone-messaging', 'dots-attachments-viewer'].every(id => { const node = document.getElementById(id); return getComputedStyle(node).backgroundColor === dotsNative.rootBackground && getComputedStyle(node.firstElementChild).backgroundColor === dotsNative.rootBackground && !node.hasAttribute('data-chatgpt-backdrop-surface'); }));
    test('matching footer decorations outside embedded Dots are preserved', !decorationAbsent(document.querySelector('#standalone-messaging ._background_fixture')));
    const protectedDotsResults = [];
    for (const [attribute, value] of [['role', 'dialog'], ['role', 'menu'], ['data-settings-page', ''], ['data-testid', 'settings-modal']]) {
      const wrapper = document.createElement('div'); wrapper.setAttribute(attribute, value); wrapper.style.display = 'none';
      const copy = dotsNativeClone.cloneNode(true); copy.removeAttribute('id'); copy.querySelectorAll('[id]').forEach(node => node.removeAttribute('id'));
      wrapper.append(copy); dotsPage.append(wrapper); await wait();
      const pane = copy.querySelector('.thread-pane');
      const footer = copy.querySelector('.conversation-footer');
      const pass = getComputedStyle(copy).backgroundColor === dotsNative.rootBackground && getComputedStyle(pane).backgroundColor === dotsNative.rootBackground && !copy.hasAttribute('data-chatgpt-backdrop-surface') &&
        !decorationAbsent(footer.querySelector('._surface_fixture')) && getComputedStyle(footer.querySelector('.composer-disclaimer')).backgroundColor === dotsNative.rootBackground && getComputedStyle(footer.querySelector('.composer-wrap')).borderBottomColor === dotsNative.rootBackground;
      protectedDotsResults.push({attribute, value, pass});
      wrapper.remove();
    }
    test('Dots matching roots and footer paint inside protected dialogs menus and settings are preserved', protectedDotsResults.every(result => result.pass));
    const dotsDiagnostic = {native: dotsNative, originalWrapStyle: dotsWrapStyle, activeSurfaces: dotsNodes.map(node => ({id: node.id, background: getComputedStyle(node).backgroundColor})), protected: protectedDotsResults};
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
    test('zero panel opacity does not restore the portaled Dots header shadow', decorationAbsent(dotsHeaderFade));
    test('zero panel opacity remains transparent through the bottom edge', alpha(bottomSidebar) === 0 && Math.abs(bottomGap()) < 0.5);
    test('zero panel opacity leaves the Dots page and composer transparent', dotsNodes.every(node => alpha(node) === 0) && alpha(document.getElementById('dots-composer')) === 0);
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: 1});
    test('full panel opacity applies equally to sidebar and titlebar cap', alpha(nativeSidebar) === 1 && alpha(nativeSidebar, '::before') === 1);
    test('full panel opacity does not restore the portaled Dots header shadow', decorationAbsent(dotsHeaderFade));
    test('full panel opacity covers the bottom edge without another paint layer', alpha(bottomSidebar) === 1 && Math.abs(bottomGap()) < 0.5);
    test('full panel opacity tints the Dots composer without hiding the page wallpaper', dotsNodes.every(node => alpha(node) === 0) && alpha(document.getElementById('dots-composer')) === 1 && alpha(document.getElementById('dots-disclaimer')) === 0);
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
    test('light mode keeps the portaled Dots header fade transparent', decorationAbsent(dotsHeaderFade));
    test('light theme work panels use white at the requested opacity', [...workPanels, dynamicSummary].every(node => {
      const channels = getComputedStyle(node).backgroundColor.match(/[\d.]+/g).map(Number);
      return channels.slice(0, 3).every(value => value === 255) && Math.abs(alpha(node) - requestedAlpha) < 0.005;
    }) && alpha(workHeader) === 0 && alpha(workHeader, '::before') === 0);
    test('light mode keeps Dots page and footer decorations transparent', dotsNodes.every(node => alpha(node) === 0) && decorationAbsent(document.getElementById('dots-footer-combined')) && alpha(document.getElementById('dots-disclaimer')) === 0 && getComputedStyle(dotsWrap).borderBottomColor === 'rgba(0, 0, 0, 0)');
    test('light mode preserves Dots native content tokens and selected composer tint', getComputedStyle(dotsBubble).backgroundColor === dotsNative.bubble && getComputedStyle(dotsReaction).backgroundColor === 'rgb(250, 250, 250)' && getComputedStyle(dotsAttachment).backgroundColor === 'rgb(250, 250, 250)' && Math.abs(alpha(document.getElementById('dots-composer')) - requestedAlpha) < 0.005 && getComputedStyle(document.getElementById('dots-composer')).backgroundColor.startsWith('rgba(255, 255, 255,'));
    document.documentElement.className = 'dark'; await wait();
    test('follows native dark theme', api.status().mode === 'dark');
    test('dark theme work panels return to the dark tint at requested opacity', [...workPanels, dynamicSummary].every(node => {
      const channels = getComputedStyle(node).backgroundColor.match(/[\d.]+/g).map(Number);
      return channels.slice(0, 3).join(',') === '24,24,27' && Math.abs(alpha(node) - requestedAlpha) < 0.005;
    }));
    const dotsPlaceholder = document.createComment('Dots fixture route placeholder');
    dotsPage.replaceWith(dotsPlaceholder); await wait();
    test('leaving Dots restores detached roots to their original marker state', !dotsPage.hasAttribute('data-chatgpt-backdrop-surface') && dotsPage.querySelector('#dots-inner-root').getAttribute('data-chatgpt-backdrop-surface') === 'prior-dots' && !dotsPage.querySelector('#dots-inner-pane').hasAttribute('data-chatgpt-backdrop-surface'));
    const dotsRouteMain = document.getElementById('main');
    const dotsRoute = dotsNativeClone.cloneNode(true);
    const dotsRouteLayer = document.querySelector('[data-chatgpt-backdrop-layer]');
    const dotsRouteImage = dotsRouteLayer.firstElementChild;
    const dotsRouteImageURL = dotsRouteImage.style.backgroundImage;
    dotsRouteMain.replaceWith(dotsRoute); await wait();
    test('SPA navigation into Dots reveals all newly mounted nested surfaces', ['dots-page', 'dots-outer-pane', 'dots-inner-root', 'dots-inner-pane'].every(id => alpha(document.getElementById(id)) === 0));
    test('SPA navigation into Dots removes newly mounted footer paint', decorationAbsent(document.getElementById('dots-footer-combined')) && alpha(document.getElementById('dots-disclaimer')) === 0 && getComputedStyle(document.getElementById('dots-composer-wrap')).borderBottomColor === 'rgba(0, 0, 0, 0)');
    test('Dots navigation preserves the existing wallpaper layer and image assignment', document.querySelector('[data-chatgpt-backdrop-layer]') === dotsRouteLayer && dotsRouteLayer.firstElementChild === dotsRouteImage && dotsRouteImage.style.backgroundImage === dotsRouteImageURL);
    dotsRoute.replaceWith(dotsRouteMain); dotsPlaceholder.replaceWith(dotsPage); await wait();
    test('SPA navigation out of Dots reveals the regular conversation again', alpha(dotsRouteMain) === 0 && !dotsRoute.hasAttribute('data-chatgpt-backdrop-surface') && dotsRoute.querySelector('#dots-inner-root').getAttribute('data-chatgpt-backdrop-surface') === 'prior-dots');
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
    dotsDiagnostic.wrapStyleBeforeCleanup = dotsWrap.getAttribute('style');
    if (dotsWrapStyle === null) dotsWrap.removeAttribute('style'); else dotsWrap.setAttribute('style', dotsWrapStyle);
    dotsDiagnostic.wrapStyleAfterCleanup = dotsWrap.getAttribute('style');
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
    test('restore returns the native Dots header gradient and its original geometry', getComputedStyle(dotsHeaderFade).backgroundImage === dotsHeaderNative.fadeImage && JSON.stringify(dotsHeaderGeometry(dotsHeaderFade)) === JSON.stringify(dotsHeaderNative.fade));
    test('restore returns Dots native page footer and border paint', dotsNodes.every(node => getComputedStyle(node).backgroundColor === dotsNative.rootBackground) && !decorationAbsent(document.getElementById('dots-footer-combined')) && getComputedStyle(document.getElementById('dots-disclaimer')).backgroundColor === dotsNative.rootBackground && getComputedStyle(dotsWrap).borderBottomColor === dotsNative.rootBackground && getComputedStyle(dotsWrap).borderBottomWidth === dotsNative.borderWidth);
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
    return {engineVersion: api.version, passed: checks.filter(check => check.pass).length, total: checks.length, settleTimeouts, focusDiagnostic, sidebarDiagnostic, titlebarCapDiagnostic, bottomGapDiagnostic, workSurfaceDiagnostic, dotsDiagnostic, dotsHeaderDiagnostic, restoreDiagnostic, gifDiagnostic, gifSupported, checks};
    """#
}
