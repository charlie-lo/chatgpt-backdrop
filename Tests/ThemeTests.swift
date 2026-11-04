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
            let arguments = CommandLine.arguments.dropFirst().filter { $0 != "--native-modules" }
            let sourceURL: URL
            if arguments.count == 1 {
                sourceURL = URL(fileURLWithPath: arguments[0])
            } else if arguments.isEmpty,
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
final class Runner: NSObject, WKNavigationDelegate, NSWindowDelegate, WKScriptMessageHandlerWithReply {
    private let engine: String
    private let resultURL: URL?
    private let nativeModuleFormat: Bool
    private var webView: WKWebView!
    private var window: NSWindow?
    private var timeout: Timer?
    private var finished = false

    init(engine: String, resultURL: URL? = nil) {
        self.engine = engine
        self.resultURL = resultURL
        nativeModuleFormat = CommandLine.arguments.contains("--native-modules") ||
            ProcessInfo.processInfo.environment["BACKDROP_TEST_NATIVE_MODULES"] == "1" ||
            Bundle.main.object(forInfoDictionaryKey: "BackdropTestModuleFormat") as? String == "native"
    }

    /// Transform only test-authored fixture class tokens. The production engine
    /// is inserted afterward, byte for byte, so compatibility is not simulated.
    private func fixtureModuleNames(_ value: String) -> String {
        guard nativeModuleFormat else { return value }
        let tokens = [
            ("_MainContentTopFade_fixture", "MainContentTopFade-T6W4RS"),
            ("_PageSurface_fixture", "PageSurface-g2Llyi"),
            ("_MainContentLeftBorder_fixture", "MainContentLeftBorder-IFAvO_"),
            ("_ComposerLayoutRoot_fixture", "ComposerLayoutRoot-XCKS7O"),
            ("_ComposerLayoutBody_fixture", "ComposerLayoutBody-uBBf1A"),
            ("_floatingHeader_fixture", "floatingHeader-tfHzDp"),
            ("_background_fixture", "background-uNUrfY"),
            ("_surface_fixture", "surface-nr8PSS"),
            ("_fade_fixture", "fade-AcMqqj"),
            ("_combined_fixture", "combined-vZM0uN")
        ]
        return tokens.reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "fixtureFocus")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        webView.navigationDelegate = self
        // WebKit pauses animation frames for a detached or fully hidden view.
        // This accessory window shows only the independent local test fixture.
        let window = NSWindow(contentRect: NSRect(x: 180, y: 120, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Backdrop DOM Tests — local fixture"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
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
        /* Dots' native transcript has row-level roles, a scrolling parent,
           and separate simple/split assistant text paint surfaces. */
        #dots-message-list{display:flex;flex:1 0 auto;flex-direction:column;gap:4px;padding-top:20px;position:relative}
        #dots-message-list>.message-row{display:flex;align-items:flex-end;margin-bottom:12px;padding-inline:20px}
        #dots-message-list>.message-row.assistant{align-items:flex-start}
        #dots-message-list>.message-row.self{justify-content:flex-end}
        .message-bubble-wrap{max-width:88%;min-width:0;position:relative}
        .message-row.assistant>.message-bubble-wrap{width:100%;max-width:100%}
        .message-surface>.message-bubble{background:rgba(170,178,190,.28);border-radius:22px;padding:12px}
        .message-surface>.message-bubble:has([data-orbit-message-parts]){background:transparent;padding:0}
        [data-orbit-message-text-part].message-bubble{background:rgba(170,178,190,.28);border-radius:22px;padding:12px}
        [data-avatar-overlay-material-variant=transcript-message]{position:relative;isolation:isolate;border-radius:22px;background:rgba(190,192,198,.3);box-shadow:0 2px 12px rgba(0,0,0,.2);backdrop-filter:blur(8px)}
        [data-avatar-overlay-material-variant=transcript-message]:not(:has([data-orbit-message-parts]))::before{content:"";position:absolute;inset:0;z-index:-1;border-radius:inherit;pointer-events:none;background:rgba(32,32,32,.9)}
        .message-bubble[data-option-picker-choice]{background:rgb(50,75,105);border-radius:18px;padding:8px;color:white}
        #dots-reading-tail{height:180px;flex:none}
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
        /* Native conversation and footer columns share the thread width token. */
        #thread-scroll{position:relative;overflow:auto;max-height:560px;width:780px;max-width:100%;margin-inline:auto;--thread-body-max-width:640px}
        [data-thread-user-message-navigation-content],#reading-footer{position:relative;box-sizing:border-box;width:calc(100% - 48px);max-width:var(--thread-body-max-width);margin-inline:auto}
        #reading-column{display:flex;flex-direction:column;gap:24px;padding-block:20px}
        #reading-column [data-content-search-unit-key]{position:relative}
        #reading-tail-spacer{height:280px;flex:none}
        #thread-scroll [aria-hidden=true][class*="_background_fixture"]{position:absolute;pointer-events:none}
        #thread-footer{position:sticky;bottom:0}
        #reading-user-bubble{display:inline-block;margin-left:auto;background:rgb(142,57,97);border-radius:18px;padding:12px;color:white}
        #reading-native-tool{background:rgba(35,38,42,.84);border:1px solid rgba(255,255,255,.15);border-radius:12px;padding:16px}
        #reading-link{color:rgb(232,132,185)}
        #main.reading-test-hidden{opacity:0}
        #reading-collapse-wrapper{overflow:hidden}
        #reading-collapse-wrapper.reading-test-collapsed{height:0}
        #reading-assistant.reading-test-contents{display:contents!important}
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
        /* Native full-page settings layout paints its outer electron surface.
           Cards own separate fills, and the scroll/group wrappers do not. */
        #settings-host{position:fixed;right:16px;top:80px;width:260px;height:190px;z-index:2;--fixture-settings-surface:rgb(24,24,24);--fixture-settings-card:rgb(34,34,34)}
        :root.light #settings-host{--fixture-settings-surface:rgb(250,250,250);--fixture-settings-card:rgb(242,242,242)}
        .settings-layout-fixture{display:flex;flex-direction:column;height:100%;min-height:0;background-color:var(--fixture-settings-surface,rgb(24,24,24))}
        .settings-scroll-fixture{flex:1;min-height:0;overflow-y:auto;scrollbar-gutter:stable}
        .settings-group-fixture{display:flex;flex-direction:column;min-height:300px}
        .settings-card-fixture{border:1px solid rgb(80,80,80);border-radius:16px;padding:10px;background:var(--fixture-settings-card,rgb(34,34,34))}
        .settings-card-fixture button,.settings-card-fixture input{color:inherit;background:rgb(55,56,57);border:1px solid rgb(90,90,90)}
        .settings-preview-fixture{background:rgb(29,30,31);border-radius:6px}
        .settings-footer-fixture{height:24px;flex:none;background:var(--fixture-settings-surface,rgb(24,24,24))}
        .settings-negative-fixtures{display:none}
        .settings-visibility-hidden{visibility:hidden}
        .settings-display-none{display:none!important}

        /* Native utility classes consume semantic tokens inherited from the
           selected Accent; composer panel paint must not replace these tokens. */
        html.dark{--fixture-accent-background:rgb(139,179,255);--fixture-accent-foreground:rgb(16,27,45);--fixture-user-background:rgb(43,67,109)}
        html.light{--fixture-accent-background:rgb(37,99,235);--fixture-accent-foreground:rgb(255,255,255);--fixture-user-background:rgb(219,232,255)}
        html.dark[data-fixture-accent=rose]{--fixture-accent-background:rgb(242,154,199);--fixture-accent-foreground:rgb(45,15,31);--fixture-user-background:rgb(102,49,79)}
        html.light[data-fixture-accent=rose]{--fixture-accent-background:rgb(190,45,115);--fixture-accent-foreground:rgb(255,255,255);--fixture-user-background:rgb(253,222,237)}
        :root{--color-background-composer-primary:var(--fixture-accent-background);--color-text-composer-primary:var(--fixture-accent-foreground);--color-background-user-message:var(--fixture-user-background);--color-text-user-message:var(--fixture-accent-foreground)}
        .bg-composer-primary{background-color:var(--color-background-composer-primary)}
        .text-composer-primary{color:var(--color-text-composer-primary)}
        .bg-user-message{background-color:var(--color-background-user-message);color:var(--color-text-user-message);border-radius:18px}
        .fixture-native-accent-control{border:0;border-radius:50%;width:28px;height:28px;outline:0 solid var(--color-background-composer-primary)}
        .fixture-native-accent-control:focus{outline-width:2px}
        .fixture-native-accent-control:disabled{opacity:.4;cursor:not-allowed}
        .fixture-messaging-accent{--messaging-send-background:rgb(36,117,78);--messaging-send-foreground:rgb(245,255,249);--color-background-composer-primary:var(--messaging-send-background);--color-text-composer-primary:var(--messaging-send-foreground)}
        .fixture-unpersonalized-composer{--color-background-composer-primary:rgb(73,74,75);--color-text-composer-primary:rgb(250,250,250)}
        /* Current app class names, exercised in every run alongside the
           selectable full-suite format. Native lookalikes retain their paint. */
        #module-compat-host{display:none}
        .MainContentTopFade-T6W4RS,.PrefixMainContentTopFade-T6W4RS,.MainContentTopFadeish-T6W4RS{height:40px;background-image:linear-gradient(rgb(24,24,27),transparent)}
        .PageSurface-g2Llyi,.FullHeightPageSurface-Spy7z1,.PrefixPageSurface-g2Llyi{box-shadow:0 0 0 .5px rgba(255,255,255,.1),-8px 0 32px rgba(0,0,0,.7)}
        .background-uNUrfY.surface-nr8PSS{height:180px;background:rgb(24,24,27)}
        .background-uNUrfY.fade-AcMqqj,.background-uNUrfY.combined-vZM0uN{height:32px;background-image:linear-gradient(to top,rgb(24,24,27),transparent)}
        .ComposerLayoutRoot-XCKS7O{--composer-layout-surface-background:rgb(24,24,27);--composer-layout-surface-shadow:var(--elevation-composer);background-color:var(--composer-layout-surface-background);box-shadow:var(--composer-layout-surface-shadow)}
        .MainContentLeftBorder-IFAvO_{border-left:.5px solid var(--app-shell-sidebar-divider)}
        .floatingHeader-tfHzDp{height:96px;background-image:linear-gradient(rgb(24,24,27),transparent)}
        </style>
        <script>
        __BACKDROP_TEST_ENGINE_SOURCE__
        window.fixtureImage = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/mZQAAAAASUVORK5CYII=';
        window.fixtureGIF87 = 'data:image/gif;base64,\(Self.animatedGIFBase64)';
        window.fixtureGIF = 'data:image/gif;base64,' + btoa('GIF89a' + atob('\(Self.animatedGIFBase64)').slice(6));
        window.titlebarControlClicks = 0;
        window.bottomControlClicks = 0;
        window.workControlClicks = 0;
        window.readingControlClicks = 0;
        window.readingLinkClicks = 0;
        window.beforeDOM = __chatGPTBackdrop.apply({imageData: fixtureImage});
        </script></head><body>
        <div id="root" data-app-shell-page-sidebar="true" data-app-shell-page-surface="true" data-app-shell-frame>
          <div id="page-shadow" class="_PageSurface_fixture" aria-hidden="true"></div>
          <div id="page-with-controls" class="_PageSurface_fixture" aria-hidden="true"><button type="button">Preserved page controls</button></div>
          <header id="titlebar" data-app-shell-titlebar><button id="titlebar-control" type="button" onclick="titlebarControlClicks++">Back</button><span id="titlebar-label">Title</span><div data-app-shell-main-content-top-fade="visible"><div id="header-fade" class="_MainContentTopFade_fixture" aria-hidden="true"></div></div></header>
          <aside id="sidebar" class="app-shell-left-panel" data-app-shell-left-panel-appearance="translucent"><div id="navigation-rail">Home</div><div id="sidebar-content"><div id="sidebar-header" class="_FloatingHeader_fixture" data-app-shell-left-panel-appearance="translucent">Sidebar</div><nav id="sidebar-navigation" class="sidebar-navigation">Navigation</nav></div><div id="sidebar-resize-wrapper" class="group/panel-resizer"><div id="sidebar-resize-handle" role="separator" aria-orientation="vertical" tabindex="0"><div id="sidebar-resize-line" class="sidebar-resize-handle-line"></div></div></div></aside>
          <aside id="content-sidebar" class="app-shell-left-panel" data-app-shell-left-panel-appearance="content-surface">Content surface</aside>
          <aside id="peeking-sidebar" class="app-shell-left-panel" data-app-shell-left-panel-appearance="translucent" data-slate-sidebar-peeking="true">Peeking sidebar</aside>
          <section id="module-compat-host" data-app-shell-main-content-layout>
            <div data-app-shell-main-content-top-fade="visible">
              <div id="module-fade-first" class="MainContentTopFade-T6W4RS background-j0etS7" aria-hidden="true"></div>
              <div id="module-fade-later" class="pointer-events-none MainContentTopFade-T6W4RS background-j0etS7" aria-hidden="true"></div>
              <div id="module-fade-lookalike" class="PrefixMainContentTopFade-T6W4RS" aria-hidden="true"></div>
              <div id="module-fade-near-name" class="MainContentTopFadeish-T6W4RS" aria-hidden="true"></div>
              <div id="module-fade-controls" class="MainContentTopFade-T6W4RS" aria-hidden="true"><button type="button">Retained control</button></div>
            </div>
            <div id="module-page-first" class="PageSurface-g2Llyi" aria-hidden="true"></div>
            <div id="module-page-later" class="pointer-events-none PageSurface-g2Llyi" aria-hidden="true"></div>
            <div id="module-page-full-height" class="FullHeightPageSurface-Spy7z1" aria-hidden="true"></div>
            <div id="module-page-lookalike" class="PrefixPageSurface-g2Llyi" aria-hidden="true"></div>
            <div id="module-page-controls" class="PageSurface-g2Llyi" aria-hidden="true"><button type="button">Retained page control</button></div>
            <div class="thread-scroll-container"><div id="module-footer-surface" class="background-uNUrfY surface-nr8PSS" aria-hidden="true"></div><div id="module-footer-fade" class="pointer-events-none background-uNUrfY fade-AcMqqj" aria-hidden="true"></div><div id="module-footer-combined" class="background-uNUrfY combined-vZM0uN" aria-hidden="true"></div></div>
            <div id="module-native-border" class="MainContentLeftBorder-IFAvO_"></div>
            <section id="module-native-composer" class="relative ComposerLayoutRoot-XCKS7O" data-composer-surface-variant="default"><button type="button">Native composer control</button></section>
            <div id="module-native-dots-fade" class="pointer-events-none floatingHeader-tfHzDp" aria-hidden="true" style="position-anchor: --orbit-messaging-header-compat"></div>
            <div role="dialog" data-app-shell-frame><div data-app-shell-main-content-top-fade><div id="module-dialog-fade" class="MainContentTopFade-T6W4RS" aria-hidden="true"></div></div><div id="module-dialog-page" class="PageSurface-g2Llyi" aria-hidden="true"></div><div class="thread-scroll-container"><div id="module-dialog-footer" class="background-uNUrfY fade-AcMqqj" aria-hidden="true"></div></div></div>
            <div role="menu" data-app-shell-frame><div data-app-shell-main-content-top-fade><div id="module-menu-fade" class="MainContentTopFade-T6W4RS" aria-hidden="true"></div></div><div id="module-menu-page" class="PageSurface-g2Llyi" aria-hidden="true"></div></div>
          </section>
          <main id="main" class="_MainContentLeftBorder_fixture" data-chatgpt-backdrop-surface="prior-main" data-app-shell-page-surface>
            <article data-message-author-role="assistant"><p>Message text</p><pre><code>const unchanged = true;</code></pre></article>
            <div role="dialog"><div data-message-author-role="assistant">Protected dialog content</div><div data-thread-footer-background><div id="dialog-decoration" class="_background_fixture _fade_fixture" aria-hidden="true"></div></div><div id="dialog-left-border" class="_MainContentLeftBorder_fixture">Native dialog border</div></div>
            <div id="unrelated-gradient">Unrelated content decoration</div>
            <div id="native-menu" role="menu"><div data-composer-surface-variant="default">Native menu</div></div>
            <div id="document-composer" class="_ComposerLayoutRoot_fixture" data-composer-surface-variant="document"><div contenteditable="true">Document editor</div></div>
            <div id="inline-composer" class="_ComposerLayoutRoot_fixture" data-composer-surface-variant="inline"><div contenteditable="true">Inline editor</div></div>
            <div id="thread-scroll" class="thread-scroll-container" data-thread-footer-background style="--thread-footer-background-offset:0px">
              <div id="reading-column" data-thread-user-message-navigation-content data-chatgpt-backdrop-reading="prior-reading">
                <section id="reading-assistant" data-content-search-unit-key="assistant-1"><div id="reading-assistant-inner" data-message-author-role="assistant"><p id="reading-text">Readable conversation text stays sharp and selectable.</p><a id="reading-link" href="#reading-link-target" onclick="event.preventDefault();readingLinkClicks++">Open a useful reference</a><div id="reading-nested-tool-unit" data-content-search-unit-key="assistant-1-tool"><div id="reading-native-tool">Native tool card <button id="reading-control" type="button" onclick="readingControlClicks++">View result</button></div></div><pre id="reading-code"><code>const reading = true;</code></pre></div></section>
                <div id="reading-collapse-wrapper"><section id="reading-tool" data-content-search-unit-key="tool-2"><p>A separate tool result group.</p></section></div>
                <div id="reading-local-turn" data-turn-key="local-turn"><div class="flex flex-col"><div id="reading-local-group" class="flex flex-col"><p>Local agent activity without a search-unit wrapper.</p></div><div id="reading-local-user-group" class="flex flex-col"><div class="group/user-message">Local user input stays native.</div></div></div></div>
                <div data-turn-key="virtual-turn"><div id="reading-virtual-group" data-virtualized-turn-content>A virtualized assistant response.</div></div>
                <section id="reading-user" data-content-search-unit-key="user-3" data-local-conversation-user-anchor="user-3"><div data-message-author-role="user"><div id="reading-user-bubble">Keep my native user bubble color.</div></div></section>
                <div id="reading-tail-spacer" aria-hidden="true"></div>
              </div>
              <div><div aria-hidden="true" class="pointer-events-none sticky bottom-0"><div id="footer-fade" class="_background_fixture _fade_fixture pointer-events-none absolute" aria-hidden="true"></div></div></div>
              <div id="thread-footer" data-thread-scroll-footer="true"><div id="footer-surface" class="_background_fixture _surface_fixture pointer-events-none absolute bg-surface" aria-hidden="true"></div><div id="reading-footer" data-pip-obstacle="thread-footer"><form data-chatgpt-composer data-thread-find-composer="true" data-composer-placement="thread"><section id="thread-composer" class="_ComposerLayoutRoot_fixture" data-composer-dark data-composer-surface-variant="default" data-composer-utility-bar-variant="default" data-composer-layout="single-line"><div id="composer-body" class="_ComposerLayoutBody_fixture" data-composer-body data-composer-layout="single-line"><div contenteditable="true" id="prompt-textarea">Composer</div></div><button id="composer-control" type="button">Send</button></section></form></div></div>
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
              <div class="conversation-viewport"><div id="dots-scroll" class="messages-scroll" data-role="messages-scroll"><div id="dots-message-list" class="message-list" data-chatgpt-backdrop-reading="prior-dots-reading">
                <div class="message-row self"><div id="dots-bubble" class="message-bubble">Native blue message</div></div>
                <div id="dots-reading-simple-row" class="message-row assistant"><div class="message-bubble-wrap"><div class="message-surface"><div id="dots-reading-simple" class="message-bubble"><div data-markdown-text-style="assistant-message"><p id="dots-reading-text">A normal assistant reply without split-part markers.</p><a id="dots-reading-link" href="#dots-reading-link" onclick="event.preventDefault();window.dotsReadingLinkClicks=(window.dotsReadingLinkClicks||0)+1">Reference</a></div></div></div><button id="dots-reading-reaction" class="dots-reaction" type="button" onclick="window.dotsReadingReactionClicks=(window.dotsReadingReactionClicks||0)+1">React</button></div></div>
                <div id="dots-reading-rich-row" class="message-row assistant"><div class="message-bubble-wrap"><div class="message-surface"><div class="message-bubble"><div data-orbit-message-parts><div id="dots-reading-material" data-avatar-overlay-material-variant="transcript-message" data-transcript-role="assistant"><div id="dots-reading-part" class="message-bubble" data-orbit-message-text-part data-markdown-text-style="assistant-message">One text part in a response with a rich result.</div></div><div id="dots-reading-attachment" class="dots-attachment" data-orbit-message-block="attachment">Native attachment result</div><button id="dots-reading-choice" class="message-bubble" data-option-picker-choice type="button">Keep this native choice</button><pre id="dots-reading-code"><code>const dotsReading = true;</code></pre></div></div></div></div></div>
                <div class="message-row"><div class="message-bubble-wrap"><div class="message-surface"><div id="dots-reading-human" class="message-bubble">An incoming human message stays native.</div></div></div></div>
                <button id="dots-reaction" class="dots-reaction" type="button">Reaction</button><div id="dots-attachment" class="dots-attachment">Attachment card</div>
                <div id="dots-reading-tail" aria-hidden="true"></div>
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
        let renderedFixture = fixtureModuleNames(fixture).replacingOccurrences(of: "__BACKDROP_TEST_ENGINE_SOURCE__", with: engine)
        webView.loadHTMLString(renderedFixture, baseURL: URL(string: "https://backdrop-test.invalid/"))
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
                let value = try await webView.callAsyncJavaScript(self?.fixtureModuleNames(Self.assertions) ?? Self.assertions, arguments: [:], in: nil, contentWorld: .page)
                guard var object = value as? [String: Any],
                      var checks = object["checks"] as? [[String: Any]], let self else {
                    self?.finish(error: "WebKit returned an unexpected result: \(String(describing: value))")
                    return
                }
                object["fixtureModuleFormat"] = self.nativeModuleFormat ? "native" : "legacy"
                object["nativeFocusBefore"] = nativeFocusBefore
                object["nativeFocusAfter"] = ["applicationActive": NSApp.isActive,
                                             "keyWindow": self.window?.isKeyWindow ?? false]
                let readingRendering = await self.verifyReadingBlurRendering()
                checks.append(contentsOf: readingRendering.checks)
                object["readingBlurRendering"] = readingRendering.diagnostic
                if object["gifSupported"] as? Bool == true {
                    let animation = await self.verifyGIFAnimation()
                    checks.append(contentsOf: animation.checks)
                    object["gifAnimation"] = animation.diagnostic
                    object["checks"] = checks
                    object["passed"] = checks.filter { ($0["pass"] as? Bool) == true }.count
                    object["total"] = checks.count
                }
                object["checks"] = checks
                object["passed"] = checks.filter { ($0["pass"] as? Bool) == true }.count
                object["total"] = checks.count
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

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            replyHandler(["appActive": NSApp.isActive, "windowKey": self?.window?.isKeyWindow ?? false], nil)
        }
    }

    /// Probes an empty transcript region and calibrates its native snapshot
    /// coordinates. WKSnapshot can omit compositor backdrop filters even when
    /// the actual window renders them, so blur variance is diagnostic only.
    /// ShowBlurDiagnostic keeps a production-engine comparison visible for
    /// separate actual-display verification, rather than claiming a pixel pass.
    private func verifyReadingBlurRendering() async -> (checks: [[String: Any]], diagnostic: [String: Any]) {
        let names = ["local reading blur fixture renders real high-frequency wallpaper pixels",
                     "native snapshot calibration samples the intended fixture coordinates"]
        var checks = names.map { ["name": $0, "pass": false] as [String: Any] }
        var diagnostic: [String: Any] = [:]
        do {
            let value = try await webView.callAsyncJavaScript("""
            const root = document.getElementById('root'); root.style.visibility = 'visible';
            const viewport = document.getElementById('thread-scroll');
            scrollTo(0, Math.max(0, viewport.getBoundingClientRect().top + scrollY - 64));
            viewport.scrollTop = viewport.scrollHeight;
            globalThis.__chatGPTBackdrop.apply({imageData: patternImage, opacity: 0, blur: 0, panelOpacity: 0, readingMode: 'sheet', readingOpacity: 0, readingBlur: 0});
            await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
            const spacer = document.getElementById('reading-tail-spacer').getBoundingClientRect();
            const view = viewport.getBoundingClientRect();
            const left = Math.max(spacer.left, view.left, 0), right = Math.min(spacer.right, view.right, innerWidth);
            const top = Math.max(spacer.top, view.top, 44), bottom = Math.min(spacer.bottom, view.bottom - 80, innerHeight - 20);
            if (right - left < 64 || bottom - top < 64) throw new Error('The empty reading region is too small for a native blur sample.');
            const plate = document.querySelector('[data-chatgpt-backdrop-reading-layer]:not([data-chatgpt-backdrop-reading-context="dots"])'), r = plate?.getBoundingClientRect(), s = plate && getComputedStyle(plate);
            return {x: (left + right - 64) / 2, y: (top + bottom - 64) / 2, width: 64, height: 64, plateCount: [...document.querySelectorAll('[data-chatgpt-backdrop-reading-layer]:not([data-chatgpt-backdrop-reading-context="dots"])')].filter(node => getComputedStyle(node).display !== 'none').length,
              plateRect: r && {left:r.left,top:r.top,width:r.width,height:r.height}, blur:s?.backdropFilter || s?.webkitBackdropFilter,
              clip:s?.clipPath, mode:globalThis.__chatGPTBackdrop.status().readingMode, parentContain:plate?.parentElement && getComputedStyle(plate.parentElement).contain};
            """, arguments: ["patternImage": "data:image/png;base64," + Self.patternImageBase64], in: nil, contentWorld: .page)
            guard let box = value as? [String: Any],
                  let x = box["x"] as? Double, let y = box["y"] as? Double,
                  let width = box["width"] as? Double, let height = box["height"] as? Double else {
                throw NSError(domain: "ThemeTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected native reading sample rectangle."])
            }
            diagnostic["sample"] = box
            diagnostic["webViewFlipped"] = webView.isFlipped
            diagnostic["webViewBounds"] = ["width": webView.bounds.width, "height": webView.bounds.height]
            let rect = NSRect(x: x, y: y, width: width, height: height)
            try await Task.sleep(nanoseconds: 120_000_000)
            let before = try await wallpaperPixelStatistics(rect: rect, label: "before")
            let afterStyle = try await webView.callAsyncJavaScript("""
            globalThis.__chatGPTBackdrop.apply({imageData: patternImage, opacity: 0, blur: 0, panelOpacity: 0, readingMode: 'sheet', readingOpacity: 0, readingBlur: 16});
            await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
            const plate=document.querySelector('[data-chatgpt-backdrop-reading-layer]:not([data-chatgpt-backdrop-reading-context="dots"])'),r=plate.getBoundingClientRect(),s=getComputedStyle(plate);
            return {rect:{left:r.left,top:r.top,width:r.width,height:r.height},blur:s.backdropFilter||s.webkitBackdropFilter,clip:s.clipPath,mode:globalThis.__chatGPTBackdrop.status().readingMode};
            """, arguments: ["patternImage": "data:image/png;base64," + Self.patternImageBase64], in: nil, contentWorld: .page)
            diagnostic["afterStyle"] = afterStyle
            try await Task.sleep(nanoseconds: 120_000_000)
            let after = try await wallpaperPixelStatistics(rect: rect, label: "after")
            diagnostic["before"] = before; diagnostic["after"] = after
            let beforeVariance = before["variance"] ?? 0
            let afterVariance = after["variance"] ?? 1
            checks[0]["pass"] = beforeVariance > 0.03 && (box["plateCount"] as? Int) == 1
            diagnostic["snapshotBackdropFilter"] = afterVariance < beforeVariance * 0.55 ? "captured" : "not reflected in snapshot"
            diagnostic["blurVerification"] = "Computed blur and scope are asserted in DOM checks. Actual compositor blur requires the optional production-engine display comparison; snapshot variance is not a pass/fail assertion."
            // An independent foreground patch verifies the JS viewport point
            // maps to the native full-view bitmap, including document scroll.
            _ = try await webView.callAsyncJavaScript("""
            const probe = document.createElement('div'); probe.id='native-snapshot-calibration';
            Object.assign(probe.style,{position:'fixed',left:x+'px',top:y+'px',width:'64px',height:'64px',background:'rgb(220,30,50)',zIndex:'2147483647'});
            document.body.append(probe); await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return true;
            """, arguments: ["x": x, "y": y], in: nil, contentWorld: .page)
            try await Task.sleep(nanoseconds: 120_000_000)
            let calibration = try await wallpaperPixelStatistics(rect: rect, label: "calibration")
            diagnostic["calibration"] = calibration
            diagnostic["snapshotMethod"] = "full WKWebView viewport bitmap, sampled at scaled JS viewport coordinates"
            checks[1]["pass"] = (calibration["meanRed"] ?? 0) > 0.7 && (calibration["meanGreen"] ?? 1) < 0.25 && (calibration["meanBlue"] ?? 1) < 0.3 && (calibration["variance"] ?? 1) < 0.001
            _ = try await webView.evaluateJavaScript("document.getElementById('native-snapshot-calibration')?.remove()")
        } catch {
            diagnostic["error"] = error.localizedDescription
        }
        // Preserve the original native GIF-frame checks' setup exactly.
        _ = try? await webView.callAsyncJavaScript("""
        document.getElementById('native-snapshot-calibration')?.remove();
        globalThis.__chatGPTBackdrop.apply({imageData: fixtureGIF, opacity: 0, blur: 0, panelOpacity: 0, readingMode: 'none'});
        document.getElementById('root').style.visibility = 'hidden';
        scrollTo(0, 0); await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
        return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        return (checks, diagnostic)
    }

    private func wallpaperPixelStatistics(rect: NSRect, label: String) async throws -> [String: Double] {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: webView.bounds.width)
        configuration.afterScreenUpdates = true
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            throw NSError(domain: "ThemeTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "The native reading sample has no bitmap."])
        }
        if Bundle.main.object(forInfoDictionaryKey: "ShowBlurDiagnostic") as? Bool == true,
           let resultURL, let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: resultURL.deletingPathExtension().appendingPathExtension(label + ".png"), options: .atomic)
        }
        var total = 0.0, squared = 0.0, count = 0.0
        var red = 0.0, green = 0.0, blue = 0.0
        let scaleX = Double(bitmap.pixelsWide) / webView.bounds.width
        let scaleY = Double(bitmap.pixelsHigh) / webView.bounds.height
        let left = Int((rect.minX + 4) * scaleX), right = Int((rect.maxX - 4) * scaleX)
        let top = Int((rect.minY + 4) * scaleY), bottom = Int((rect.maxY - 4) * scaleY)
        for y in stride(from: top, to: min(bottom, bitmap.pixelsHigh), by: 2) {
            for x in stride(from: left, to: min(right, bitmap.pixelsWide), by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let light = Double(color.redComponent) * 0.2126 + Double(color.greenComponent) * 0.7152 + Double(color.blueComponent) * 0.0722
                total += light; squared += light * light; count += 1
                red += Double(color.redComponent); green += Double(color.greenComponent); blue += Double(color.blueComponent)
            }
        }
        guard count > 0 else { throw NSError(domain: "ThemeTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "The native reading sample contains no pixels."]) }
        let mean = total / count
        return ["mean": mean, "variance": max(0, squared / count - mean * mean), "samples": count,
                "meanRed": red / count, "meanGreen": green / count, "meanBlue": blue / count]
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
        writeTestResult(to: resultURL, success: error == nil, checks: assertions, error: error)
        if Bundle.main.object(forInfoDictionaryKey: "ShowBlurDiagnostic") as? Bool == true,
           let window = window {
            webView.navigationDelegate = nil
            webView.loadHTMLString("""
            <!doctype html><html class="dark"><head><meta charset="utf-8"><style>
            html,body{margin:0;color:white;font:18px -apple-system}
            .thread-scroll-container{position:fixed;inset:90px 24px 24px;overflow:auto}
            [data-thread-user-message-navigation-content]{position:absolute;box-sizing:border-box;left:54%;top:0;width:44%;height:100%;padding:24px}
            .label{position:fixed;padding:8px 12px;background:#111e;border-radius:6px;z-index:10;pointer-events:none;font-size:15px}
            .reference{position:fixed;box-sizing:border-box;left:48px;top:114px;width:40%;padding:12px;background:#111b;border-radius:8px}
            button{font:inherit;color:inherit;background:#303035;border:1px solid #aaa;border-radius:6px;padding:8px 12px;margin-right:8px}
            .actions{position:fixed;left:48px;bottom:48px;z-index:10;padding:12px;background:#111e;border-radius:8px}
            </style></head><body>
            <div class="label" style="left:24px;top:10px">Production engine — real displayed Sheet blur; close to finish</div>
            <div class="label" style="left:48px;top:52px">Unplated wallpaper reference</div><div class="label" style="left:58%;top:52px">Sheet plate · opacity 0 · blur 16</div>
            <div class="thread-scroll-container"><div data-thread-user-message-navigation-content><p>Text stays sharp above the local background blur.</p><p>Select this sentence to verify native text selection.</p><a href="#comparison-link" style="color:#9bf">Native link</a></div></div>
            <div class="reference">The checkerboard should remain sharp outside the bounded chat column.</div>
            <div class="actions"><button onclick="setReadingBlur(0)">Blur 0</button><button onclick="setReadingBlur(16)">Blur 16</button></div>
            <script>\(engine)</script>
            <script>function setReadingBlur(value){globalThis.__chatGPTBackdrop.apply({imageData:'data:image/png;base64,\(Self.patternImageBase64)',opacity:0,blur:0,panelOpacity:0,readingMode:'sheet',readingOpacity:0,readingBlur:value});document.querySelectorAll('.label')[2].textContent='Sheet plate · opacity 0 · blur '+value;}setReadingBlur(16);</script>
            </body></html>
            """, baseURL: URL(string: "https://backdrop-test.invalid/"))
            window.title = "Backdrop Blur Comparison — actual display"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if Bundle.main.object(forInfoDictionaryKey: "ShowTestSummary") as? Bool == true,
           let window = window {
            let checks = assertions?["checks"] as? [[String: Any]] ?? []
            let passed = checks.filter { ($0["pass"] as? Bool) == true }.count
            let failures = checks.filter { ($0["pass"] as? Bool) != true }
                .compactMap { $0["name"] as? String }
            let title = error == nil ? "PASS \(passed)/\(checks.count) — Readability Tests" : "FAIL — Readability Tests"
            let summary = NSTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 390))
            summary.isEditable = false
            summary.isSelectable = true
            summary.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            summary.textColor = .labelColor
            summary.backgroundColor = .windowBackgroundColor
            summary.textContainerInset = NSSize(width: 18, height: 18)
            summary.string = title + "\n\n" + (error ?? "All isolated page checks passed.") +
                (failures.isEmpty ? "" : "\n\n" + failures.joined(separator: "\n")) +
                "\n\nThis fixture never connects to ChatGPT.\nClose this window to finish."
            window.contentView = summary
            window.setContentSize(NSSize(width: 650, height: 390))
            window.title = title
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        window?.orderOut(nil)
        if let error { fputs("FAIL: \(error)\n", stderr); exit(1) }
        exit(0)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private static let patternImageBase64: String = {
        let size = 256
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 0, to: size, by: 2) {
            for x in stride(from: 0, to: size, by: 2) where ((x + y) / 2) % 2 == 0 {
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.base64EncodedString()
    }()

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
    const settingsHost = document.createElement('div');
    settingsHost.id = 'settings-host'; settingsHost.setAttribute('data-app-shell-main-surface', 'default');
    settingsHost.innerHTML = `<div id="settings-layout" class="settings-layout-fixture flex h-full min-h-0 flex-col electron:overflow-hidden electron:bg-surface windows:rounded-tl-lg">
      <div id="settings-scroll" class="settings-scroll-fixture flex-1 scrollbar-stable overflow-y-auto"><div id="settings-group" class="settings-group-fixture group/settings mx-auto flex w-full flex-col" data-density="default">
        <header>General</header><div class="flex flex-col"><section id="settings-card" class="settings-card-fixture"><button id="settings-toggle" role="switch" type="button" aria-checked="false" onclick="window.settingsControlClicks=(window.settingsControlClicks||0)+1">Native setting</button><input id="settings-input" type="text" value="Original setting"><div>Native card text</div><article id="settings-preview" class="settings-preview-fixture" data-message-author-role="assistant">Native settings preview</article></section></div>
      </div></div><footer id="settings-footer" class="settings-footer-fixture">Native action footer</footer></div>`;
    const settingsAncestor = document.createElement('div'); settingsAncestor.id = 'settings-ancestor';
    settingsAncestor.append(settingsHost); document.getElementById('root').append(settingsAncestor);
    const settingsLayout = document.getElementById('settings-layout');
    const settingsScroll = document.getElementById('settings-scroll');
    const settingsGroup = document.getElementById('settings-group');
    const settingsCard = document.getElementById('settings-card');
    const settingsToggle = document.getElementById('settings-toggle');
    const settingsInput = document.getElementById('settings-input');
    const settingsNativeClone = settingsLayout.cloneNode(true);
    const settingsPreview = document.getElementById('settings-preview');
    const settingsFooter = document.getElementById('settings-footer');
    const settingsNegatives = document.createElement('div'); settingsNegatives.className = 'settings-negative-fixtures';
    const settingsNegativeRoots = [];
    const settingsCloneWithoutIDs = () => { const copy = settingsNativeClone.cloneNode(true); copy.removeAttribute('id'); copy.querySelectorAll('[id]').forEach(node => node.removeAttribute('id')); return copy; };
    for (const variant of ['embedded', 'missing-density', 'wrong-nesting', 'outside-app-surface', 'dialog', 'menu', 'settings-modal']) {
      const copy = settingsCloneWithoutIDs();
      const wrapper = document.createElement('div');
      if (variant !== 'outside-app-surface') wrapper.setAttribute('data-app-shell-main-surface', 'default');
      if (variant === 'embedded') copy.classList.remove('electron:bg-surface');
      if (variant === 'missing-density') copy.querySelector('[data-density]').removeAttribute('data-density');
      if (variant === 'wrong-nesting') { const group = copy.querySelector('[data-density]'); const extra = document.createElement('div'); group.replaceWith(extra); extra.append(group); }
      if (variant === 'dialog' || variant === 'menu') wrapper.setAttribute('role', variant);
      if (variant === 'settings-modal') wrapper.setAttribute('data-testid', 'settings-modal');
      wrapper.append(copy); settingsNegatives.append(wrapper); settingsNegativeRoots.push({variant, node: copy});
    }
    document.getElementById('root').append(settingsNegatives);
    const settingsNative = {
      layoutBackground: getComputedStyle(settingsLayout).backgroundColor,
      cardBackground: getComputedStyle(settingsCard).backgroundColor,
      cardBorder: getComputedStyle(settingsCard).border,
      cardRadius: getComputedStyle(settingsCard).borderRadius,
      buttonBackground: getComputedStyle(settingsToggle).backgroundColor,
      inputBackground: getComputedStyle(settingsInput).backgroundColor,
      previewBackground: getComputedStyle(settingsPreview).backgroundColor,
      footerBackground: getComputedStyle(settingsFooter).backgroundColor,
      scrollOverflow: getComputedStyle(settingsScroll).overflowY,
      scrollHeight: settingsScroll.scrollHeight,
      scrollClientHeight: settingsScroll.clientHeight
    };
    test('native settings fixture reproduces its independent opaque page fill', settingsNative.layoutBackground === 'rgb(24, 24, 24)' && settingsNative.cardBackground === 'rgb(34, 34, 34)');

    const accentButtons = prefix => `<button id="${prefix}-send" type="button" class="fixture-native-accent-control bg-composer-primary text-composer-primary">↑</button><button id="${prefix}-stop" type="button" class="fixture-native-accent-control bg-composer-primary text-composer-primary">■</button><button id="${prefix}-disabled" type="button" disabled class="fixture-native-accent-control bg-composer-primary text-composer-primary">↑</button>`;
    document.getElementById('thread-composer').insertAdjacentHTML('beforeend', accentButtons('accent-thread'));
    document.getElementById('home-composer-body').insertAdjacentHTML('beforeend', accentButtons('accent-home'));
    document.getElementById('dots-composer').classList.add('fixture-messaging-accent');
    document.getElementById('dots-composer').insertAdjacentHTML('beforeend', accentButtons('accent-dots'));
    document.getElementById('reading-user').insertAdjacentHTML('beforeend', '<div id="accent-user" data-message-author-role="user" class="bg-user-message">A native Accent-colored user bubble.</div>');
    const accentReferences = document.createElement('div');
    accentReferences.id = 'accent-native-references'; accentReferences.setAttribute('role', 'menu'); accentReferences.hidden = true;
    accentReferences.innerHTML = `<div>${accentButtons('accent-reference')}</div><div class="fixture-messaging-accent">${accentButtons('accent-dots-reference')}</div><div class="fixture-unpersonalized-composer">${accentButtons('accent-unpersonalized-reference')}</div><div id="accent-user-reference" data-message-author-role="user" class="bg-user-message">Native reference</div>`;
    const unpersonalizedComposer = document.createElement('section');
    unpersonalizedComposer.id = 'accent-unpersonalized-composer'; unpersonalizedComposer.className = '_ComposerLayoutRoot_fixture fixture-unpersonalized-composer';
    unpersonalizedComposer.setAttribute('data-composer-surface-variant', 'default');
    unpersonalizedComposer.innerHTML = accentButtons('accent-unpersonalized');
    document.getElementById('main').append(unpersonalizedComposer, accentReferences);
    const moduleByID = id => document.getElementById(id);
    const modulePaint = id => {
      const style = getComputedStyle(moduleByID(id));
      return {image: style.backgroundImage, background: style.backgroundColor, shadow: style.boxShadow, border: style.borderLeftColor, borderWidth: style.borderLeftWidth};
    };
    const moduleNativeIDs = ['module-fade-first','module-fade-later','module-page-first','module-page-later','module-footer-surface','module-footer-fade','module-footer-combined','module-native-border','module-native-composer','module-native-dots-fade'];
    const moduleGuardIDs = ['module-fade-lookalike','module-fade-near-name','module-fade-controls','module-page-full-height','module-page-lookalike','module-page-controls','module-dialog-fade','module-dialog-page','module-dialog-footer','module-menu-fade','module-menu-page'];
    const moduleBefore = Object.fromEntries([...moduleNativeIDs, ...moduleGuardIDs].map(id => [id, modulePaint(id)]));
    test('current module fixture reproduces the native top fade and page shadow', moduleBefore['module-fade-first'].image.includes('linear-gradient') && moduleBefore['module-page-first'].shadow !== 'none');
    const baseline = document.documentElement.outerHTML;
    const accentPaint = id => {
      const style = getComputedStyle(document.getElementById(id));
      return {background: style.backgroundColor, foreground: style.color, outline: style.outlineColor, opacity: style.opacity, radius: style.borderRadius};
    };
    const sameAccentPaint = (id, reference) => JSON.stringify(accentPaint(id)) === JSON.stringify(accentPaint(reference));
    const nativeAccentClass = document.documentElement.getAttribute('class');
    const nativeAccentAttribute = document.documentElement.getAttribute('data-fixture-accent');
    const initialAccentPaint = accentPaint('accent-reference-send');
    test('native Accent fixture gives thread Home and Dots controls their own semantic colors', ['accent-thread-send', 'accent-home-send'].every(id => sameAccentPaint(id, 'accent-reference-send')) && sameAccentPaint('accent-dots-send', 'accent-dots-reference-send') && initialAccentPaint.background !== accentPaint('accent-dots-send').background);
    test('native Accent fixture paints the user role itself rather than a colored child', sameAccentPaint('accent-user', 'accent-user-reference') && accentPaint('accent-user').background !== initialAccentPaint.background);
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
    test('full settings page reveals the wallpaper through its outer layout', alpha(settingsLayout) === 0 && getComputedStyle(settingsLayout).backgroundImage === 'none' && alpha(settingsScroll) === 0 && alpha(settingsGroup) === 0);
    test('settings cards retain native fill border and corner geometry', getComputedStyle(settingsCard).backgroundColor === settingsNative.cardBackground && getComputedStyle(settingsCard).border === settingsNative.cardBorder && getComputedStyle(settingsCard).borderRadius === settingsNative.cardRadius);
    test('settings controls retain native paint state and values', getComputedStyle(settingsToggle).backgroundColor === settingsNative.buttonBackground && getComputedStyle(settingsInput).backgroundColor === settingsNative.inputBackground && settingsToggle.getAttribute('aria-checked') === 'false' && settingsInput.value === 'Original setting');
    test('settings preview and action footer retain their native fills', getComputedStyle(settingsPreview).backgroundColor === settingsNative.previewBackground && getComputedStyle(settingsFooter).backgroundColor === settingsNative.footerBackground && !settingsPreview.hasAttribute('data-chatgpt-backdrop-surface'));
    test('settings content group remains outside structural transparency markers', !settingsGroup.hasAttribute('data-chatgpt-backdrop-surface') && !settingsCard.hasAttribute('data-chatgpt-backdrop-surface'));
    settingsScroll.scrollTop = 48;
    test('settings scrolling retains native overflow dimensions and behavior', getComputedStyle(settingsScroll).overflowY === settingsNative.scrollOverflow && settingsNative.scrollOverflow === 'auto' && settingsScroll.scrollTop === 48 && settingsScroll.scrollHeight === settingsNative.scrollHeight && settingsScroll.clientHeight === settingsNative.scrollClientHeight);
    settingsScroll.scrollTop = 0;
    const settingsButtonBox = settingsToggle.getBoundingClientRect();
    test('settings switch remains reachable by pointer hit testing', document.elementFromPoint(settingsButtonBox.left + settingsButtonBox.width / 2, settingsButtonBox.top + settingsButtonBox.height / 2) === settingsToggle);
    settingsToggle.click(); test('settings control handler remains functional', window.settingsControlClicks === 1);
    if (window.webkit?.messageHandlers?.fixtureFocus) await window.webkit.messageHandlers.fixtureFocus.postMessage({});
    settingsInput.focus(); await wait();
    test('settings text input receives focus without changing its native value', document.activeElement === settingsInput && settingsInput.matches(':focus') && settingsInput.value === 'Original setting');
    settingsInput.blur();
    settingsGroup.setAttribute('data-density', 'compact'); await wait();
    test('compact settings retain wallpaper and native card fills', alpha(settingsLayout) === 0 && getComputedStyle(settingsCard).backgroundColor === settingsNative.cardBackground);
    settingsGroup.setAttribute('data-density', 'default');
    test('embedded malformed and out-of-scope settings layouts retain their own background', settingsNegativeRoots.filter(item => ['embedded', 'missing-density', 'wrong-nesting', 'outside-app-surface'].includes(item.variant)).every(item => alpha(item.node) === 1 && !item.node.hasAttribute('data-chatgpt-backdrop-surface')));
    test('settings layouts inside dialogs menus and settings modals remain protected', settingsNegativeRoots.filter(item => ['dialog', 'menu', 'settings-modal'].includes(item.variant)).every(item => alpha(item.node) === 1 && !item.node.hasAttribute('data-chatgpt-backdrop-surface')));
    const settingsWallpaperLayer = document.querySelector('[data-chatgpt-backdrop-layer]');
    const settingsWallpaperImage = settingsWallpaperLayer.firstElementChild;
    const settingsWallpaperURL = settingsWallpaperImage.style.backgroundImage;
    const settingsRouteCopy = settingsNativeClone.cloneNode(true);
    settingsLayout.replaceWith(settingsRouteCopy); await wait();
    test('SPA navigation into settings clears newly mounted page fill and preserves cards', alpha(settingsRouteCopy) === 0 && getComputedStyle(settingsRouteCopy.querySelector('.settings-card-fixture')).backgroundColor === settingsNative.cardBackground);
    test('leaving a settings page restores its detached structural markers', !settingsLayout.hasAttribute('data-chatgpt-backdrop-surface') && !settingsScroll.hasAttribute('data-chatgpt-backdrop-surface'));
    settingsRouteCopy.replaceWith(settingsLayout); await wait();
    test('settings route changes preserve the decoded wallpaper layer and image', document.querySelector('[data-chatgpt-backdrop-layer]') === settingsWallpaperLayer && settingsWallpaperLayer.firstElementChild === settingsWallpaperImage && settingsWallpaperImage.style.backgroundImage === settingsWallpaperURL && !settingsRouteCopy.hasAttribute('data-chatgpt-backdrop-surface'));
    const settingsPathDiagnostic = {initialURL: location.href};
    const settingsHistoryState = history.state;
    const settingsOriginalURL = location.href;
    const settingsPlaceholder = document.createComment('Settings route placeholder');
    const setFixturePath = async path => { history.replaceState(settingsHistoryState, '', path); dispatchEvent(new PopStateEvent('popstate')); await wait(); };
    try {
      await setFixturePath('/settings/general');
      settingsPathDiagnostic.settingsURL = location.href;
      test('a recognized full settings route keeps the wallpaper active', api.status().mode !== 'paused' && getComputedStyle(settingsWallpaperLayer).display !== 'none' && alpha(settingsLayout) === 0);
      api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: requestedAlpha}); await wait();
      test('reapplying while native settings is open preserves its wallpaper and cards', api.status().mode !== 'paused' && alpha(settingsLayout) === 0 && getComputedStyle(settingsCard).backgroundColor === settingsNative.cardBackground);
      settingsLayout.replaceWith(settingsPlaceholder); await wait();
      test('an unknown settings layout retains the original paused protection', api.status().mode === 'paused' && getComputedStyle(settingsWallpaperLayer).display === 'none');
      settingsPlaceholder.replaceWith(settingsLayout); await wait();
      test('mounting a recognized settings page resumes the wallpaper without Apply', api.status().mode !== 'paused' && getComputedStyle(settingsWallpaperLayer).display !== 'none' && alpha(settingsLayout) === 0);
      // Mount a cached layout while hidden, then reveal it using only an
      // attribute update. Neither reveal nor later transitions may rely on
      // Apply, a route event, or inserting/removing a DOM element.
      settingsLayout.hidden = true;
      settingsLayout.replaceWith(settingsPlaceholder); await wait();
      settingsPlaceholder.replaceWith(settingsLayout); await wait();
      test('mounting a cached hidden settings page keeps its wallpaper paused', api.status().mode === 'paused' && getComputedStyle(settingsWallpaperLayer).display === 'none');
      settingsLayout.removeAttribute('hidden'); await wait();
      test('revealing an already mounted settings layout resumes wallpaper without Apply', api.status().mode !== 'paused' && getComputedStyle(settingsWallpaperLayer).display !== 'none' && alpha(settingsLayout) === 0);
      const cachedSettingsCases = [];
      const settingsWallpaperPaused = () => api.status().mode === 'paused' && document.documentElement.getAttribute('data-chatgpt-backdrop-muted') === document.documentElement.getAttribute('data-chatgpt-backdrop') && getComputedStyle(settingsWallpaperLayer).display === 'none';
      const settingsWallpaperActive = () => api.status().mode !== 'paused' && document.documentElement.getAttribute('data-chatgpt-backdrop-muted') !== document.documentElement.getAttribute('data-chatgpt-backdrop') && getComputedStyle(settingsWallpaperLayer).display !== 'none' && alpha(settingsLayout) === 0;
      for (const [targetName, target] of [['layout', settingsLayout], ['host', settingsHost], ['ancestor', settingsAncestor]]) {
        for (const [attribute, value] of [['hidden', ''], ['inert', ''], ['aria-hidden', 'true'], ['role', 'dialog'], ['data-testid', 'settings-modal'], ['data-settings-page', ''], ['style', 'visibility:hidden'], ['style', 'display:none']]) {
          const original = target.getAttribute(attribute);
          target.setAttribute(attribute, value); await wait();
          const paused = settingsWallpaperPaused();
          if (original === null) target.removeAttribute(attribute); else target.setAttribute(attribute, original);
          await wait();
          const resumed = settingsWallpaperActive();
          cachedSettingsCases.push({target: targetName, attribute, value, paused, resumed});
          test('settings ' + targetName + ' ' + attribute + '=' + value + ' automatically pauses and resumes wallpaper', paused && resumed);
        }
        const originalClass = target.getAttribute('class');
        for (const className of ['settings-visibility-hidden', 'settings-display-none']) {
          target.classList.add(className); await wait();
          const paused = settingsWallpaperPaused();
          if (originalClass === null) target.removeAttribute('class'); else target.setAttribute('class', originalClass);
          await wait();
          const resumed = settingsWallpaperActive();
          cachedSettingsCases.push({target: targetName, className, paused, resumed});
          test('settings ' + targetName + ' ' + className + ' class automatically pauses and resumes wallpaper', paused && resumed);
        }
      }
      const settingsStructureCases = [];
      for (const [targetName, target, attribute, temporaryValue] of [
        ['content', settingsGroup, 'data-density', null],
        ['content', settingsGroup, 'class', settingsGroup.className.replace('group/settings', 'unrecognized-settings')],
        ['layout', settingsLayout, 'class', settingsLayout.className.replace('electron:bg-surface', 'electron:bg-unrecognized')],
        ['host', settingsHost, 'data-app-shell-main-surface', null]
      ]) {
        const original = target.getAttribute(attribute);
        if (temporaryValue === null) target.removeAttribute(attribute); else target.setAttribute(attribute, temporaryValue);
        await wait();
        const paused = settingsWallpaperPaused();
        if (original === null) target.removeAttribute(attribute); else target.setAttribute(attribute, original);
        await wait();
        const resumed = settingsWallpaperActive();
        settingsStructureCases.push({target: targetName, attribute, paused, resumed});
        test('restoring recognized settings ' + targetName + ' ' + attribute + ' automatically resumes wallpaper', paused && resumed);
      }
      settingsPathDiagnostic.cachedSettingsCases = cachedSettingsCases;
      settingsPathDiagnostic.structureCases = settingsStructureCases;
      test('automatic settings visibility transitions preserve the original wallpaper layer and decoded image', document.querySelector('[data-chatgpt-backdrop-layer]') === settingsWallpaperLayer && settingsWallpaperLayer.firstElementChild === settingsWallpaperImage && settingsWallpaperImage.style.backgroundImage === settingsWallpaperURL);
      test('restoring the visible settings layout resumes its native wallpaper treatment', settingsWallpaperActive() && getComputedStyle(settingsCard).backgroundColor === settingsNative.cardBackground);
      const authPaths = [];
      for (const path of ['/login', '/auth/callback', '/billing']) {
        await setFixturePath(path); authPaths.push({path, paused: api.status().mode === 'paused' && getComputedStyle(settingsWallpaperLayer).display === 'none'});
      }
      settingsPathDiagnostic.authPaths = authPaths;
      test('login auth and billing remain protected even when a settings layout is mounted', authPaths.every(item => item.paused));
    } catch (error) {
      settingsPathDiagnostic.error = String(error);
      test('the local settings route fixture can exercise same-origin history transitions', false);
    } finally {
      if (settingsPlaceholder.isConnected) settingsPlaceholder.replaceWith(settingsLayout);
      history.replaceState(settingsHistoryState, '', settingsOriginalURL); dispatchEvent(new PopStateEvent('popstate')); await wait();
    }
    test('returning from settings paths preserves the same active wallpaper image', api.status().mode !== 'paused' && document.querySelector('[data-chatgpt-backdrop-layer]') === settingsWallpaperLayer && settingsWallpaperLayer.firstElementChild === settingsWallpaperImage && settingsWallpaperImage.style.backgroundImage === settingsWallpaperURL);
    const settingsDiagnostic = {native: settingsNative, paths: settingsPathDiagnostic, activeBackground: getComputedStyle(settingsLayout).backgroundColor, negativeRoots: settingsNegativeRoots.map(item => ({variant: item.variant, background: getComputedStyle(item.node).backgroundColor}))};
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
    test('current top fade token at class start is cleared', decorationAbsent(moduleByID('module-fade-first')));
    test('current top fade token after utility classes is cleared', decorationAbsent(moduleByID('module-fade-later')));
    test('current page shadow token at class start is cleared', getComputedStyle(moduleByID('module-page-first')).boxShadow === 'none');
    test('current page shadow token after utility classes is cleared', getComputedStyle(moduleByID('module-page-later')).boxShadow === 'none');
    test('current footer surface fade and combined layers are cleared', ['module-footer-surface','module-footer-fade','module-footer-combined'].every(id => decorationAbsent(moduleByID(id))));
    test('current sidebar hairline clears only its paint', getComputedStyle(moduleByID('module-native-border')).borderLeftColor === 'rgba(0, 0, 0, 0)' && getComputedStyle(moduleByID('module-native-border')).borderLeftWidth === moduleBefore['module-native-border'].borderWidth);
    test('current composer root follows panel opacity without broad shadow', Math.abs(alpha(moduleByID('module-native-composer')) - requestedAlpha) < 0.005 && getComputedStyle(moduleByID('module-native-composer')).boxShadow === 'none');
    test('current Dots floating fade is cleared with its native anchor', getComputedStyle(moduleByID('module-native-dots-fade')).backgroundImage === 'none');
    test('similar component names and control-bearing wrappers retain their paint', moduleGuardIDs.slice(0, 6).every(id => JSON.stringify(modulePaint(id)) === JSON.stringify(moduleBefore[id])));
    test('current module classes in protected dialogs and menus retain their paint', moduleGuardIDs.slice(6).every(id => JSON.stringify(modulePaint(id)) === JSON.stringify(moduleBefore[id])));
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
    const hostFocus = window.webkit?.messageHandlers?.fixtureFocus ? await window.webkit.messageHandlers.fixtureFocus.postMessage({}) : null;
    documentEditor.focus(); await wait();
    const focusDiagnostic = {
      hostFocus,
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
    test('light mode reveals the settings wallpaper while retaining light native cards', alpha(settingsLayout) === 0 && getComputedStyle(settingsCard).backgroundColor === 'rgb(242, 242, 242)' && getComputedStyle(settingsToggle).backgroundColor === settingsNative.buttonBackground);
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
    const accentMatchesNative = () => ['send', 'stop', 'disabled'].every(state =>
      ['thread', 'home'].every(context => sameAccentPaint('accent-' + context + '-' + state, 'accent-reference-' + state)) &&
      sameAccentPaint('accent-dots-' + state, 'accent-dots-reference-' + state) &&
      sameAccentPaint('accent-unpersonalized-' + state, 'accent-unpersonalized-reference-' + state)) &&
      sameAccentPaint('accent-user', 'accent-user-reference');
    const accentLayer = document.querySelector('[data-chatgpt-backdrop-layer]');
    const accentImage = accentLayer.firstElementChild;
    const accentURL = accentImage.style.backgroundImage;
    for (const scheme of ['light', 'dark']) {
      document.documentElement.className = scheme; await wait();
      let previousAccent = null;
      for (const selectedAccent of ['blue', 'rose']) {
        // This models the native preference updating root tokens while the
        // background remains applied: deliberately do not call api.apply here.
        document.documentElement.setAttribute('data-fixture-accent', selectedAccent); await wait();
        const expected = accentPaint('accent-reference-send');
        test(scheme + ' ' + selectedAccent + ' Accent updates thread and Home send stop and disabled colors', ['send', 'stop', 'disabled'].every(state => ['thread', 'home'].every(context => sameAccentPaint('accent-' + context + '-' + state, 'accent-reference-' + state))) && (previousAccent === null || expected.background !== previousAccent));
        test(scheme + ' ' + selectedAccent + ' Accent preserves local Dots and unpersonalized composer palettes', ['send', 'stop', 'disabled'].every(state => sameAccentPaint('accent-dots-' + state, 'accent-dots-reference-' + state) && sameAccentPaint('accent-unpersonalized-' + state, 'accent-unpersonalized-reference-' + state)));
        test(scheme + ' ' + selectedAccent + ' Accent preserves the native user bubble fill text and radius', sameAccentPaint('accent-user', 'accent-user-reference'));
        const focusButton = document.getElementById('accent-thread-send');
        focusButton.focus({preventScroll: true}); await wait();
        test(scheme + ' ' + selectedAccent + ' native button focus outline follows Accent', document.activeElement === focusButton && getComputedStyle(focusButton).outlineWidth === '2px' && getComputedStyle(focusButton).outlineColor === expected.background);
        focusButton.blur();
        previousAccent = expected.background;
      }
    }
    for (const panelOpacity of [0, 1]) {
      api.apply({imageData: fixtureImage, opacity: 0, panelOpacity}); await wait();
      test(panelOpacity * 100 + ' percent Panel Opacity preserves native Accent colors and disabled treatment', accentMatchesNative() && Number(getComputedStyle(document.getElementById('accent-thread-disabled')).opacity) === 0.4 && Math.abs(alpha(document.getElementById('thread-composer')) - panelOpacity) < 0.005);
    }
    for (const readingMode of ['none', 'sheet', 'cards', 'focus']) {
      api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: requestedAlpha, readingMode}); await wait();
      test(readingMode + ' reading mode preserves native Accent controls and user bubble styling', accentMatchesNative());
    }
    test('changing native Accent and reading controls retains the wallpaper instance', document.querySelector('[data-chatgpt-backdrop-layer]') === accentLayer && accentLayer.firstElementChild === accentImage && accentImage.style.backgroundImage === accentURL);
    if (nativeAccentClass === null) document.documentElement.removeAttribute('class'); else document.documentElement.setAttribute('class', nativeAccentClass);
    if (nativeAccentAttribute === null) document.documentElement.removeAttribute('data-fixture-accent'); else document.documentElement.setAttribute('data-fixture-accent', nativeAccentAttribute);
    api.apply({imageData: fixtureImage, opacity: 0, panelOpacity: requestedAlpha}); await wait();
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
    // Reading treatments are independent of the surrounding panel tint. The
    // fixture uses the renderer's centered content and sticky footer structure.
    const readingViewport = document.getElementById('thread-scroll');
    const readingColumn = document.getElementById('reading-column');
    const readingFooter = document.getElementById('reading-footer');
    const readingText = document.getElementById('reading-text');
    const readingUser = document.getElementById('reading-user-bubble');
    const readingNativeTool = document.getElementById('reading-native-tool');
    const readingCode = document.getElementById('reading-code');
    const readingViewportStyle = readingViewport.getAttribute('style');
    const originalReadingScroll = readingViewport.scrollTop;
    const originalWindowScroll = {x: scrollX, y: scrollY};
    const baseReadingConfig = {imageData: fixtureImage, opacity: 0, blur: 0, panelOpacity: requestedAlpha};
    const settleReading = async () => { await wait(); await wait(); };
    const allReadingPlates = () => [...document.querySelectorAll('[data-chatgpt-backdrop-reading-layer]')];
    const plates = () => allReadingPlates().filter(node => node.getAttribute('data-chatgpt-backdrop-reading-context') !== 'dots');
    const visiblePlates = () => plates().filter(node => getComputedStyle(node).display !== 'none');
    const clippedRect = node => {
      const rect = node.getBoundingClientRect();
      const clip = getComputedStyle(node).clipPath || getComputedStyle(node).webkitClipPath;
      const tokens = /^inset\(([^)]*)\)$/.exec(clip || '')?.[1].split(/\s+round\s+/)[0].trim().split(/\s+/).map(parseFloat) || [];
      const inset = tokens.length === 1 ? [tokens[0], tokens[0], tokens[0], tokens[0]] :
        tokens.length === 2 ? [tokens[0], tokens[1], tokens[0], tokens[1]] :
        tokens.length === 3 ? [tokens[0], tokens[1], tokens[2], tokens[1]] : tokens.length >= 4 ? tokens.slice(0, 4) : [0,0,0,0];
      return {left: rect.left + inset[3], right: rect.right - inset[1], top: rect.top + inset[0], bottom: rect.bottom - inset[2]};
    };
    const viewClip = () => {
      const rect = readingViewport.getBoundingClientRect();
      return {left: Math.max(0, rect.left), right: Math.min(innerWidth, rect.right), top: Math.max(0, rect.top), bottom: Math.min(innerHeight, rect.bottom)};
    };
    const inside = (inner, outer) => inner.left >= outer.left - 1 && inner.right <= outer.right + 1 && inner.top >= outer.top - 1 && inner.bottom <= outer.bottom + 1;
    const intersects = (a, b) => Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1;
    const backdropBlur = node => getComputedStyle(node).getPropertyValue('backdrop-filter') || getComputedStyle(node).getPropertyValue('-webkit-backdrop-filter');
    const maskImage = node => getComputedStyle(node).getPropertyValue('mask-image') || getComputedStyle(node).getPropertyValue('-webkit-mask-image');
    api.apply(baseReadingConfig); await settleReading();
    test('older theme payloads default to None readability', api.status().readingMode === 'none' && api.status().readingSurfaceCount === 0 && plates().length === 0);
    test('None preserves a pre-existing unrelated column marker', readingColumn.getAttribute('data-chatgpt-backdrop-reading') === 'prior-reading');
    const readingNoneBaseline = document.documentElement.outerHTML;
    const originalUserColor = getComputedStyle(readingUser).backgroundColor;
    const originalUserRadius = getComputedStyle(readingUser).borderRadius;
    const originalToolColor = getComputedStyle(readingNativeTool).backgroundColor;
    const originalToolRadius = getComputedStyle(readingNativeTool).borderRadius;
    const originalReadingCodeColor = getComputedStyle(readingCode).backgroundColor;
    const originalReadingCodeShadow = getComputedStyle(readingCode).boxShadow;
    const originalColumnPosition = getComputedStyle(readingColumn).position;
    readingViewport.scrollTop = 0;
    scrollTo(0, Math.max(0, readingViewport.getBoundingClientRect().top + scrollY - 64)); await settleReading();
    const readingDiagnostic = {modes: []};
    for (const readingMode of ['sheet', 'cards', 'focus']) {
      api.apply({...baseReadingConfig, readingMode, readingOpacity: 0.64, readingBlur: 9}); await settleReading();
      const all = plates(); const visible = visiblePlates(); const expected = readingMode === 'cards' ? 4 : 1;
      readingDiagnostic.modes.push({mode: readingMode, total: all.length, visible: visible.length,
        rects: visible.map(node => ({...clippedRect(node), alpha: alpha(node), blur: backdropBlur(node), mask: maskImage(node)}))});
      test(readingMode + ' reports its selected mode and actual visible surface count', api.status().readingMode === readingMode && api.status().readingSurfaceCount === allReadingPlates().filter(node => getComputedStyle(node).display !== 'none').length);
      test(readingMode + ' paints the expected independent surface count', all.length === expected && visible.length === expected);
      test(readingMode + ' plates use independent reading opacity', visible.every(node => Math.abs(alpha(node) - 0.64) < 0.005));
      test(readingMode + ' leaves the surrounding sidebar opacity unchanged', Math.abs(alpha(nativeSidebar) - requestedAlpha) < 0.005);
      test(readingMode + ' applies local blur behind content only', visible.every(node => /blur\(9px\)/.test(backdropBlur(node))) && getComputedStyle(readingText).filter === 'none' && getComputedStyle(readingColumn).filter === 'none' && getComputedStyle(readingViewport).filter === 'none' && getComputedStyle(readingText).opacity === '1');
      test(readingMode + ' plates remain hidden from accessibility and pointer input', visible.every(node => getComputedStyle(node).pointerEvents === 'none' && node.closest('[aria-hidden="true"]') !== null));
      test(readingMode + ' reading paint stays inside the conversation viewport', visible.every(node => inside(clippedRect(node), viewClip())));
      test(readingMode + ' leaves native user bubble styling unchanged', getComputedStyle(readingUser).backgroundColor === originalUserColor && getComputedStyle(readingUser).borderRadius === originalUserRadius);
      test(readingMode + ' leaves native result card styling unchanged', getComputedStyle(readingNativeTool).backgroundColor === originalToolColor && getComputedStyle(readingNativeTool).borderRadius === originalToolRadius);
      test(readingMode + ' preserves native code formatting and shadow', getComputedStyle(readingCode).backgroundColor === originalReadingCodeColor && getComputedStyle(readingCode).boxShadow === originalReadingCodeShadow);
      test(readingMode + ' preserves menu and dialog surfaces', getComputedStyle(nativeMenu).backgroundColor === menuBG && getComputedStyle(nativeMenu).boxShadow === menuShadow && getComputedStyle(dialog).backgroundColor === dialogBG);
      test(readingMode + ' does not rewrite native layout or unrelated markers', getComputedStyle(readingColumn).position === originalColumnPosition && readingColumn.getAttribute('data-chatgpt-backdrop-reading') === 'prior-reading');
      test(readingMode + ' avoids a second tint on assistant wrappers', alpha(document.getElementById('reading-assistant-inner')) === 0);
      if (readingMode === 'sheet') {
        const rect = visible[0]?.getBoundingClientRect(); const col = readingColumn.getBoundingClientRect();
        test('Sheet follows the native bounded chat column width', !!rect && Math.abs(rect.left - col.left) < 1 && Math.abs(rect.width - col.width) < 1);
        test('Sheet is one continuous rounded plate including the composer area', visible.length === 1 && parseFloat(getComputedStyle(visible[0]).borderRadius) >= 12 && clippedRect(visible[0]).bottom >= Math.min(readingFooter.getBoundingClientRect().bottom, viewClip().bottom) - 1);
        test('Sheet has no feather mask', maskImage(visible[0]) === 'none');
      } else if (readingMode === 'cards') {
        const cardRects = visible.map(clippedRect);
        test('Cards do not duplicate nested assistant or tool wrappers', cardRects.length === 4 && cardRects.filter(rect => intersects(rect, document.getElementById('reading-assistant').getBoundingClientRect())).length === 1);
        test('Cards include source-shaped local and virtualized activity groups', cardRects.some(rect => intersects(rect, document.getElementById('reading-local-group').getBoundingClientRect())) && cardRects.some(rect => intersects(rect, document.getElementById('reading-virtual-group').getBoundingClientRect())));
        test('Cards do not paint user input groups', cardRects.every(rect => !intersects(rect, document.getElementById('reading-user').getBoundingClientRect()) && !intersects(rect, document.getElementById('reading-local-user-group').getBoundingClientRect())));
        test('Cards retain separate rounded backgrounds without a global column plate', visible.every(node => node.getAttribute('data-chatgpt-backdrop-reading-kind') === 'card' && parseFloat(getComputedStyle(node).borderRadius) >= 12 && maskImage(node) === 'none'));
      } else {
        const rect = visible[0]?.getBoundingClientRect(); const col = readingColumn.getBoundingClientRect();
        test('Focus uses a feathered mask with no hard card boundary', visible.length === 1 && /linear-gradient\(/.test(maskImage(visible[0])) && getComputedStyle(visible[0]).borderRadius === '0px' && getComputedStyle(visible[0]).boxShadow === 'none');
        test('Focus reaches into the gutter while staying within the main pane', !!rect && rect.width >= col.width && rect.width <= readingViewport.getBoundingClientRect().width + 1);
      }
      const selection = getSelection(); const range = document.createRange(); range.selectNodeContents(readingText); selection.removeAllRanges(); selection.addRange(range);
      test(readingMode + ' keeps conversation text selectable', selection.toString() === readingText.textContent); selection.removeAllRanges();
      const control = document.getElementById('reading-control'); const beforeControl = readingControlClicks;
      control.click();
      test(readingMode + ' keeps native result controls functional', readingControlClicks === beforeControl + 1 && getComputedStyle(control).pointerEvents === 'auto');
      const beforeLink = readingLinkClicks; document.getElementById('reading-link').click();
      test(readingMode + ' keeps links functional', readingLinkClicks === beforeLink + 1);
    }
    // Reuse active reading plates across a native theme change, preserving
    // independent strength and the light theme's neutral white backplate.
    document.documentElement.className = 'light'; await settleReading();
    for (const readingMode of ['sheet', 'cards', 'focus']) {
      api.apply({...baseReadingConfig, readingMode, readingOpacity: 0.64, readingBlur: 9}); await settleReading();
      const expected = readingMode === 'cards' ? 4 : 1;
      test(readingMode + ' uses white reading paint at independent strength in light mode', visiblePlates().length === expected && visiblePlates().every(node => {
        const channels = getComputedStyle(node).backgroundColor.match(/[\d.]+/g).map(Number);
        return channels.slice(0, 3).every(value => value === 255) && Math.abs(alpha(node) - 0.64) < 0.005 && /blur\(9px\)/.test(backdropBlur(node));
      }));
      test(readingMode + ' preserves light native panel tint and sharp conversation content', Math.abs(alpha(nativeSidebar) - requestedAlpha) < 0.005 && getComputedStyle(nativeSidebar).backgroundColor.startsWith('rgba(255, 255, 255,') && getComputedStyle(readingText).filter === 'none' && getComputedStyle(readingText).opacity === '1');
    }
    document.documentElement.className = 'dark'; await settleReading();
    // Route changes must clean detached scopes and discover the returning
    // conversation without requiring Apply or restarting the wallpaper.
    const readingRouteMain = document.getElementById('main');
    const readingRouteLayer = document.querySelector('[data-chatgpt-backdrop-layer]');
    const readingRouteImage = readingRouteLayer.firstElementChild;
    const readingRouteURL = readingRouteImage.style.backgroundImage;
    for (const readingMode of ['sheet', 'cards', 'focus']) {
      api.apply({...baseReadingConfig, readingMode, readingOpacity: 0.64, readingBlur: 9}); await settleReading();
      const emptyRoute = document.createElement('main');
      emptyRoute.id = 'reading-route-away'; emptyRoute.textContent = 'Another native route';
      readingRouteMain.replaceWith(emptyRoute); await settleReading();
      test(readingMode + ' navigation away removes reading plates and detached scope markers', api.status().readingMode === readingMode && plates().length === 0 && !readingViewport.hasAttribute('data-chatgpt-backdrop-reading'));
      emptyRoute.replaceWith(readingRouteMain);
      scrollTo(0, Math.max(0, readingViewport.getBoundingClientRect().top + scrollY - 64)); await settleReading();
      const expected = readingMode === 'cards' ? 4 : 1;
      test(readingMode + ' navigation back recreates one treatment per target without replacing wallpaper', api.status().readingMode === readingMode && plates().length === expected && visiblePlates().length === expected && readingViewport.hasAttribute('data-chatgpt-backdrop-reading') && document.querySelector('[data-chatgpt-backdrop-layer]') === readingRouteLayer && readingRouteLayer.firstElementChild === readingRouteImage && readingRouteImage.style.backgroundImage === readingRouteURL);
    }
    api.apply({...baseReadingConfig, readingMode: 'cards', readingOpacity: 0.64, readingBlur: 9}); await settleReading();
    const incomingResponse = document.createElement('section');
    incomingResponse.setAttribute('data-content-search-unit-key', 'incoming-assistant');
    incomingResponse.innerHTML = '<div data-message-author-role="assistant"><p>A newly streamed response group.</p></div>';
    readingColumn.prepend(incomingResponse); await settleReading();
    test('Cards automatically discovers newly mounted assistant groups without duplicate nested cards', plates().length === 5 && visiblePlates().filter(node => intersects(clippedRect(node), incomingResponse.getBoundingClientRect())).length === 1 && alpha(incomingResponse.firstElementChild) === 0);
    incomingResponse.remove(); await settleReading();
    test('Cards removes the plate for a detached assistant group', plates().length === 4 && api.status().readingMode === 'cards');
    api.apply({...baseReadingConfig, readingMode: 'sheet', readingOpacity: 0.64, readingBlur: 9}); await settleReading();
    const stableSheet = visiblePlates()[0]; let idleElementMutations = 0;
    const idleObserver = new MutationObserver(records => { idleElementMutations += records.reduce((count, record) => count + [...record.addedNodes, ...record.removedNodes].filter(node => node.nodeType === 1).length, 0); });
    idleObserver.observe(layer, {childList: true, subtree: true}); await settleReading(); idleObserver.disconnect();
    test('an idle reading mode does not continuously recreate owned layers', idleElementMutations === 0 && visiblePlates()[0] === stableSheet);
    readingViewport.style.width = '620px'; await settleReading();
    const resizedSheet = visiblePlates()[0]?.getBoundingClientRect(); const resizedColumn = readingColumn.getBoundingClientRect();
    test('Sheet tracks native column resizing', !!resizedSheet && Math.abs(resizedSheet.width - resizedColumn.width) < 1 && Math.abs(resizedSheet.left - resizedColumn.left) < 1);
    api.apply({...baseReadingConfig, readingMode: 'cards', readingOpacity: 0.64, readingBlur: 9}); await settleReading();
    readingViewport.scrollTop = 90; await settleReading();
    test('Cards stay clipped while the native transcript scrolls', readingViewport.scrollTop > 0 && visiblePlates().length > 0 && visiblePlates().every(node => inside(clippedRect(node), viewClip())));
    readingViewport.scrollTop = 0; await settleReading();
    const gapStyle = document.createElement('style'); gapStyle.textContent = '#reading-column{gap:2px!important}'; document.head.append(gapStyle); await settleReading();
    const closeCardRects = visiblePlates().map(clippedRect).sort((a,b) => a.top - b.top);
    test('Cards do not multiply opacity when native response groups have small gaps', closeCardRects.length > 1 && closeCardRects.every((rect,index) => index === 0 || closeCardRects[index-1].bottom <= rect.top + 1));
    gapStyle.remove(); await settleReading();
    const collapseWrapper = document.getElementById('reading-collapse-wrapper');
    const collapseClass = collapseWrapper.getAttribute('class'); collapseWrapper.classList.add('reading-test-collapsed'); await settleReading();
    test('collapsed overflow groups do not leave ghost Cards behind', collapseWrapper.getBoundingClientRect().height === 0 && document.getElementById('reading-tool').getBoundingClientRect().height > 0 && visiblePlates().length === 3);
    if (collapseClass === null) collapseWrapper.removeAttribute('class'); else collapseWrapper.setAttribute('class', collapseClass); await settleReading();
    test('expanding a native overflow group automatically restores one card', visiblePlates().length === 4 && api.status().readingMode === 'cards');
    const contentsUnit = document.getElementById('reading-assistant'); const contentsClass = contentsUnit.getAttribute('class');
    contentsUnit.classList.add('reading-test-contents'); await settleReading();
    test('display-contents search wrappers fall back to one visible assistant card', contentsUnit.getBoundingClientRect().width === 0 && document.getElementById('reading-assistant-inner').getBoundingClientRect().width > 0 && visiblePlates().length === 4);
    if (contentsClass === null) contentsUnit.removeAttribute('class'); else contentsUnit.setAttribute('class', contentsClass); await settleReading();
    api.apply({...baseReadingConfig, readingMode: 'sheet', readingOpacity: 0.64, readingBlur: 9}); await settleReading();
    readingViewport.style.visibility = 'hidden'; await settleReading();
    test('CSS-hidden conversation panes leave no ghost reading plate or scope', readingViewport.getBoundingClientRect().width > 0 && visiblePlates().length === 0 && !readingViewport.hasAttribute('data-chatgpt-backdrop-reading'));
    if (readingViewportStyle === null) readingViewport.removeAttribute('style'); else readingViewport.setAttribute('style', readingViewportStyle);
    await settleReading();
    test('restoring pane visibility automatically reactivates exactly one reading plate', visiblePlates().length === 1 && api.status().readingSurfaceCount >= 1);
    const readingMain = document.getElementById('main'); const readingMainClass = readingMain.getAttribute('class');
    readingMain.classList.add('reading-test-hidden'); await settleReading();
    test('transparent native ancestor panes do not leave a reading overlay behind', getComputedStyle(readingMain).opacity === '0' && readingViewport.getBoundingClientRect().width > 0 && visiblePlates().length === 0 && !readingViewport.hasAttribute('data-chatgpt-backdrop-reading'));
    if (readingMainClass === null) readingMain.removeAttribute('class'); else readingMain.setAttribute('class', readingMainClass);
    await settleReading();
    test('restoring an ancestor class automatically reactivates one reading plate', visiblePlates().length === 1 && api.status().readingSurfaceCount >= 1);
    api.apply({...baseReadingConfig, readingMode: 'sheet', readingOpacity: 4, readingBlur: 99}); await settleReading();
    test('reading opacity and blur clamp independently to their limits', visiblePlates().length === 1 && alpha(visiblePlates()[0]) === 1 && /blur\(24px\)/.test(backdropBlur(visiblePlates()[0])) && Math.abs(alpha(nativeSidebar) - requestedAlpha) < 0.005);
    api.apply({...baseReadingConfig, readingMode: 'sheet', readingOpacity: -5, readingBlur: -5}); await settleReading();
    test('zero reading strength does not dim text or affect native panels', visiblePlates().length === 1 && alpha(visiblePlates()[0]) === 0 && (backdropBlur(visiblePlates()[0]) === 'none' || /blur\(0px\)/.test(backdropBlur(visiblePlates()[0]))) && getComputedStyle(readingText).opacity === '1' && Math.abs(alpha(nativeSidebar) - requestedAlpha) < 0.005);
    for (let cycle = 0; cycle < 3; cycle++) {
      for (const readingMode of ['sheet', 'cards', 'focus', 'none']) { api.apply({...baseReadingConfig, readingMode}); await settleReading(); }
    }
    test('repeated mode switching leaves no reading layers in None', api.status().readingMode === 'none' && api.status().readingSurfaceCount === 0 && plates().length === 0);
    test('None removes the native reading-scope marker', !readingViewport.hasAttribute('data-chatgpt-backdrop-reading') && readingColumn.getAttribute('data-chatgpt-backdrop-reading') === 'prior-reading');
    api.apply({...baseReadingConfig, readingMode: 'not-a-mode'}); await settleReading();
    test('unknown reading modes safely fall back to None', api.status().readingMode === 'none' && plates().length === 0);
    if (readingViewportStyle === null) readingViewport.removeAttribute('style'); else readingViewport.setAttribute('style', readingViewportStyle);
    readingViewport.scrollTop = originalReadingScroll; scrollTo(originalWindowScroll.x, originalWindowScroll.y);
    api.apply(baseReadingConfig); await settleReading();
    test('None exactly restores the prior active appearance after reading controls', document.documentElement.outerHTML === readingNoneBaseline);
    // Dots uses native row roles and a separate scroll/list/pane hierarchy.
    // Keep its checks independent of the simultaneously mounted Work fixture.
    const dotsReadingBaseline = document.documentElement.outerHTML;
    const dotsReadingLayerBaseline = document.querySelector('[data-chatgpt-backdrop-layer]').outerHTML;
    const dotsReadingStyleBaseline = document.querySelector('[data-chatgpt-backdrop-style]').outerHTML;
    const dotsReadingAttributeNodes = [nativeSidebar, nativeFrame, bottomFrame, bottomSidebar, dotsPage, dotsWrap];
    const dotsReadingAttributeOrder = dotsReadingAttributeNodes.map(node => ({id: node.id, attributes: [...node.attributes].map(attribute => [attribute.name, attribute.value])}));
    const dotsPageStyle = dotsPage.getAttribute('style');
    const dotsReadingClass = document.documentElement.getAttribute('class');
    const dotsList = document.getElementById('dots-message-list');
    const dotsPane = document.getElementById('dots-inner-pane');
    const dotsSimpleRow = document.getElementById('dots-reading-simple-row');
    const dotsSimple = document.getElementById('dots-reading-simple');
    const dotsPart = document.getElementById('dots-reading-part');
    const dotsMaterial = document.getElementById('dots-reading-material');
    const dotsText = document.getElementById('dots-reading-text');
    const dotsScopeBefore = dotsList.getAttribute('data-chatgpt-backdrop-reading');
    const dotsScrollBefore = dotsScroll.scrollTop;
    const dotsPlateNodes = () => allReadingPlates().filter(node => node.getAttribute('data-chatgpt-backdrop-reading-context') === 'dots');
    const visibleDotsPlates = () => dotsPlateNodes().filter(node => getComputedStyle(node).display !== 'none');
    const paint = node => {
      const style = getComputedStyle(node);
      return {background: style.backgroundColor, color: style.color, radius: style.borderRadius, shadow: style.boxShadow, filter: style.filter, blur: backdropBlur(node), opacity: style.opacity, nativeMaterial: style.getPropertyValue('--avatar-overlay-native-material')};
    };
    const nestedMaterialAttachment = document.createElement('div');
    nestedMaterialAttachment.setAttribute('data-orbit-message-block', 'attachment');
    nestedMaterialAttachment.innerHTML = '<div id="dots-nested-native-material" data-avatar-overlay-material-variant="transcript-message">A native Material attachment inside an assistant group.</div>';
    dotsMaterial.append(nestedMaterialAttachment);
    const nestedMaterial = nestedMaterialAttachment.firstElementChild;
    const nestedMaterialNativePaint = paint(nestedMaterial);
    const dotsNativeContentPaint = () => JSON.stringify(['dots-bubble', 'dots-reading-human', 'dots-reading-reaction', 'dots-reading-attachment', 'dots-reading-choice', 'dots-reading-code', 'accent-dots-send'].map(id => paint(document.getElementById(id))));
    Object.assign(dotsPage.style, {position: 'fixed', left: '160px', top: '64px', width: '720px', height: '520px'});
    const negativeDots = [];
    for (const kind of ['standalone', 'attachments', 'reply', 'dialog']) {
      const host = document.createElement('div');
      Object.assign(host.style, {position: 'fixed', left: '-9000px', top: '0', width: '400px', height: '300px'});
      if (kind === 'reply') host.className = 'reply-chain-panel';
      if (kind === 'dialog') host.setAttribute('role', 'dialog');
      const copy = cloneWorkSurface(document.getElementById('dots-inner-root'), 'reading-negative-' + kind + '-', host);
      if (kind === 'standalone') copy.classList.remove('messaging-embedded');
      if (kind === 'attachments') copy.classList.add('messaging-attachments');
      document.getElementById('root').append(host); negativeDots.push({host, copy});
    }
    const dotsReadingConfig = {...baseReadingConfig, imageData: fixtureGIF};
    let dotsWallpaper = null, dotsWallpaperURL = null;
    for (const scheme of ['dark', 'light']) {
      document.documentElement.className = scheme;
      api.apply({...dotsReadingConfig, readingMode: 'none'}); dotsScroll.scrollTop = 0; await settleReading();
      const nativeContent = dotsNativeContentPaint();
      const nativeBacking = [paint(dotsSimple), paint(dotsPart), paint(dotsMaterial), alpha(dotsMaterial, '::before')];
      test(scheme + ' Dots fixture reproduces plain split and Material assistant backing', alpha(dotsSimple) > 0 && !dotsSimple.hasAttribute('data-orbit-message-text-part') && alpha(dotsPart) > 0 && alpha(dotsMaterial, '::before') > 0 && /blur\(8px\)/.test(backdropBlur(dotsMaterial)));
      const wallpaper = document.querySelector('[data-chatgpt-backdrop-layer]').firstElementChild;
      dotsWallpaper = wallpaper; dotsWallpaperURL = wallpaper.style.backgroundImage;
      for (const readingMode of ['sheet', 'cards', 'focus']) {
        api.apply({...dotsReadingConfig, readingMode, readingOpacity: 0.37, readingBlur: 6}); await settleReading();
        const visible = visibleDotsPlates(); const expected = readingMode === 'cards' ? 2 : 1;
        test(scheme + ' Dots ' + readingMode + ' discovers one region through nested embedded roots', dotsPlateNodes().length === expected && visible.length === expected && dotsList.getAttribute('data-chatgpt-backdrop-reading') !== dotsScopeBefore);
        test(scheme + ' Dots ' + readingMode + ' applies independent opacity and local blur without dimming text', visible.length === expected && visible.every(node => Math.abs(alpha(node) - 0.37) < 0.005 && /blur\(6px\)/.test(backdropBlur(node)) && getComputedStyle(node).pointerEvents === 'none') && getComputedStyle(dotsText).opacity === '1' && getComputedStyle(dotsText).filter === 'none' && Math.abs(alpha(nativeSidebar) - requestedAlpha) < 0.005);
        test(scheme + ' Dots ' + readingMode + ' removes all native assistant text backing rather than stacking tint', alpha(dotsSimple) === 0 && alpha(dotsPart) === 0 && alpha(dotsMaterial) === 0 && alpha(dotsMaterial, '::before') === 0 && backdropBlur(dotsMaterial) === 'none');
        test(scheme + ' Dots ' + readingMode + ' preserves user human reaction attachment code choice and Accent paint', dotsNativeContentPaint() === nativeContent);
        const pane = dotsPane.getBoundingClientRect(); const column = dotsList.getBoundingClientRect();
        const paneClip = {left: Math.max(0, pane.left), right: Math.min(innerWidth, pane.right), top: Math.max(0, pane.top), bottom: Math.min(innerHeight, pane.bottom)};
        if (readingMode === 'cards') {
          test(scheme + ' Dots Cards paint one rounded response group each and exclude user messages', visible.length === 2 && visible.every(node => node.getAttribute('data-chatgpt-backdrop-reading-kind') === 'card' && parseFloat(getComputedStyle(node).borderRadius) >= 12 && inside(clippedRect(node), paneClip)) && visible.every(node => !intersects(clippedRect(node), dotsBubble.getBoundingClientRect())));
        } else {
          const rect = visible[0]?.getBoundingClientRect();
          test(scheme + ' Dots ' + readingMode + ' spans its real transcript column and the composer overlay', !!rect && rect.width >= Math.min(column.width, pane.width) - 1 && inside(clippedRect(visible[0]), paneClip) && Math.abs(clippedRect(visible[0]).bottom - paneClip.bottom) < 1 && (readingMode === 'focus' ? /linear-gradient\(/.test(maskImage(visible[0])) && getComputedStyle(visible[0]).borderRadius === '0px' : maskImage(visible[0]) === 'none'));
        }
        api.apply({...dotsReadingConfig, readingMode, readingOpacity: 1, readingBlur: 0}); await settleReading();
        test(scheme + ' Dots ' + readingMode + ' updates live to full reading opacity without replacing plates', visibleDotsPlates().length === expected && visibleDotsPlates().every((node, index) => node === visible[index] && alpha(node) === 1 && backdropBlur(node) === 'none'));
        api.apply({...dotsReadingConfig, readingMode, readingOpacity: 0, readingBlur: 16}); await settleReading();
        test(scheme + ' Dots ' + readingMode + ' accepts zero tint with independent blur and restores native backing in None', visibleDotsPlates().length === expected && visibleDotsPlates().every(node => alpha(node) === 0 && /blur\(16px\)/.test(backdropBlur(node))) && alpha(dotsSimple) === 0);
        api.apply({...dotsReadingConfig, readingMode: 'none'}); await settleReading();
        test(scheme + ' Dots None removes treatment and exactly restores native text surfaces', dotsPlateNodes().length === 0 && dotsList.getAttribute('data-chatgpt-backdrop-reading') === dotsScopeBefore && JSON.stringify([paint(dotsSimple), paint(dotsPart), paint(dotsMaterial), alpha(dotsMaterial, '::before')]) === JSON.stringify(nativeBacking));
      }
    }
    document.documentElement.className = 'dark';
    api.apply({...dotsReadingConfig, readingMode: 'cards', readingOpacity: 0.61, readingBlur: 3}); await settleReading();
    test('Dots reading keeps nested rich-block Material paint and inherited native material settings', JSON.stringify(paint(nestedMaterial)) === JSON.stringify(nestedMaterialNativePaint) && alpha(nestedMaterial) > 0);
    const dotsPlainMarkdown = dotsSimple.querySelector('[data-markdown-text-style="assistant-message"]');
    dotsPlainMarkdown.removeAttribute('data-markdown-text-style'); dotsSimple.setAttribute('data-markdown-text-style', 'assistant-message'); await settleReading();
    test('Dots reading recognizes plain assistant markdown when its style marker is on the bubble itself', dotsPlateNodes().length === 2 && alpha(dotsSimple) === 0);
    dotsSimple.removeAttribute('data-markdown-text-style'); dotsPlainMarkdown.setAttribute('data-markdown-text-style', 'assistant-message'); await settleReading();
    test('Dots reading discovery excludes standalone attachment reply-chain and protected transcripts', negativeDots.every(({copy}) => copy.querySelector('.message-list').getAttribute('data-chatgpt-backdrop-reading') === dotsScopeBefore && alpha(copy.querySelector('.message-surface > .message-bubble')) > 0));
    const reaction = document.getElementById('dots-reading-reaction'); const link = document.getElementById('dots-reading-link');
    const reactionBefore = window.dotsReadingReactionClicks || 0, linkBefore = window.dotsReadingLinkClicks || 0;
    reaction.click(); link.click();
    const selection = getSelection(); const range = document.createRange(); range.selectNodeContents(dotsText); selection.removeAllRanges(); selection.addRange(range);
    test('Dots reading leaves reactions links and native text selection functional', window.dotsReadingReactionClicks === reactionBefore + 1 && window.dotsReadingLinkClicks === linkBefore + 1 && selection.toString() === dotsText.textContent); selection.removeAllRanges();
    const incomingDots = document.createElement('div'); incomingDots.className = 'message-row assistant';
    incomingDots.innerHTML = '<div class="message-bubble-wrap"><div class="message-surface"><div class="message-bubble"><div data-markdown-text-style="assistant-message">A newly streamed Dots response.</div></div></div></div>';
    dotsList.prepend(incomingDots); await settleReading();
    test('Dots Cards discover newly mounted plain assistant responses without duplicate text-part cards', dotsPlateNodes().length === 3 && visibleDotsPlates().filter(node => intersects(clippedRect(node), incomingDots.getBoundingClientRect())).length === 1 && alpha(incomingDots.querySelector('.message-bubble')) === 0);
    const streamingCard = visibleDotsPlates().find(node => intersects(clippedRect(node), incomingDots.getBoundingClientRect()));
    const streamingHeight = parseFloat(streamingCard?.style.height || '0');
    incomingDots.querySelector('[data-markdown-text-style]').firstChild.appendData(' Streaming response content.'.repeat(60)); await settleReading();
    test('Dots Cards track streamed text growth through native response resizing', !!streamingCard && parseFloat(streamingCard.style.height) > streamingHeight && dotsPlateNodes().includes(streamingCard));
    dotsScroll.scrollTop = 95; await settleReading();
    const scrollBox = dotsScroll.getBoundingClientRect();
    const scrollClip = {left: Math.max(0, scrollBox.left), right: Math.min(innerWidth, scrollBox.right), top: Math.max(0, scrollBox.top), bottom: Math.min(innerHeight, scrollBox.bottom)};
    test('Dots Cards follow native scrolling and clip at the intermediate messages viewport', dotsScroll.scrollTop > 0 && visibleDotsPlates().length > 0 && visibleDotsPlates().every(node => inside(clippedRect(node), scrollClip)));
    incomingDots.remove(); dotsScroll.scrollTop = 0; await settleReading();
    test('Dots Cards remove the detached streamed response treatment', dotsPlateNodes().length === 2);
    const simpleRowStyle = dotsSimpleRow.getAttribute('style'); dotsSimpleRow.style.display = 'none'; await settleReading();
    test('hiding a native Dots assistant response removes its card without reapplying settings', dotsPlateNodes().length === 1);
    if (simpleRowStyle === null) dotsSimpleRow.removeAttribute('style'); else dotsSimpleRow.setAttribute('style', simpleRowStyle); await settleReading();
    test('showing a native Dots assistant response restores exactly one card', dotsPlateNodes().length === 2);
    api.apply({...dotsReadingConfig, readingMode: 'sheet', readingOpacity: 0.61, readingBlur: 3}); await settleReading();
    const visibleDotsStyle = dotsPage.getAttribute('style'); dotsPage.style.visibility = 'hidden'; await settleReading();
    test('hidden Dots panes leave no ghost reading region or owned scope', dotsPlateNodes().length === 0 && dotsList.getAttribute('data-chatgpt-backdrop-reading') === dotsScopeBefore);
    dotsPage.setAttribute('style', visibleDotsStyle); await settleReading();
    const dotsAway = document.createElement('main'); dotsAway.textContent = 'Another native page';
    dotsPage.replaceWith(dotsAway); await settleReading();
    test('navigation away from Dots restores detached list scope and removes its plates', dotsPlateNodes().length === 0 && dotsList.getAttribute('data-chatgpt-backdrop-reading') === dotsScopeBefore);
    dotsAway.replaceWith(dotsPage); await settleReading();
    test('navigation back to Dots inherits the active reading treatment without resetting the GIF', visibleDotsPlates().length === 1 && document.querySelector('[data-chatgpt-backdrop-layer]').firstElementChild === dotsWallpaper && dotsWallpaper.style.backgroundImage === dotsWallpaperURL);
    for (const {host} of negativeDots) host.remove();
    nestedMaterialAttachment.remove();
    if (dotsPageStyle === null) dotsPage.removeAttribute('style'); else dotsPage.setAttribute('style', dotsPageStyle);
    if (dotsReadingClass === null) document.documentElement.removeAttribute('class'); else document.documentElement.setAttribute('class', dotsReadingClass);
    dotsScroll.scrollTop = dotsScrollBefore;
    // None must preserve the exact active document. A full Restore/Apply cycle
    // legitimately appends fresh owned marker attributes after fixture styles,
    // so test that separate lifecycle against native restoration below.
    api.apply(baseReadingConfig); await settleReading();
    const dotsReadingAfter = document.documentElement.outerHTML;
    let dotsReadingDifference = 0;
    while (dotsReadingDifference < Math.min(dotsReadingBaseline.length, dotsReadingAfter.length) && dotsReadingBaseline[dotsReadingDifference] === dotsReadingAfter[dotsReadingDifference]) dotsReadingDifference++;
    const dotsReadingDiagnostic = {exact: dotsReadingAfter === dotsReadingBaseline, firstDifferenceIndex: dotsReadingDifference,
      beforeContext: dotsReadingBaseline.slice(Math.max(0, dotsReadingDifference - 180), dotsReadingDifference + 220),
      afterContext: dotsReadingAfter.slice(Math.max(0, dotsReadingDifference - 180), dotsReadingDifference + 220),
      ownedLayerExact: document.querySelector('[data-chatgpt-backdrop-layer]').outerHTML === dotsReadingLayerBaseline,
      ownedStyleExact: document.querySelector('[data-chatgpt-backdrop-style]').outerHTML === dotsReadingStyleBaseline,
      attributesBefore: dotsReadingAttributeOrder,
      attributesAfter: dotsReadingAttributeNodes.map(node => ({id: node.id, attributes: [...node.attributes].map(attribute => [attribute.name, attribute.value])}))};
    test('Dots None leaves the prior active document exactly unchanged', dotsReadingAfter === dotsReadingBaseline);
    api.apply({...baseReadingConfig, readingMode: 'sheet', readingOpacity: 0.61, readingBlur: 3}); await settleReading();
    const dotsReadingWasActiveBeforeRestore = visibleDotsPlates().length === 1 && dotsList.getAttribute('data-chatgpt-backdrop-reading') !== dotsScopeBefore;
    api.restore();
    test('Restore Original directly removes active Dots reading state and restores native assistant material', dotsReadingWasActiveBeforeRestore && dotsPlateNodes().length === 0 && dotsList.getAttribute('data-chatgpt-backdrop-reading') === dotsScopeBefore && alpha(dotsSimple) > 0 && alpha(dotsMaterial, '::before') > 0 && /blur\(8px\)/.test(backdropBlur(dotsMaterial)));
    api.apply(baseReadingConfig); await settleReading();
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
    api.apply({...baseReadingConfig, readingMode: 'focus', readingOpacity: 0.64, readingBlur: 9});
    scrollTo(0, Math.max(0, readingViewport.getBoundingClientRect().top + scrollY - 64)); await settleReading();
    test('direct Restore fixture begins with an active reading treatment', api.status().readingMode === 'focus' && visiblePlates().length === 1 && readingViewport.hasAttribute('data-chatgpt-backdrop-reading'));
    api.restore();
    test('direct Restore removes active reading layers and owned scope markers', allReadingPlates().length === 0 && !readingViewport.hasAttribute('data-chatgpt-backdrop-reading') && readingColumn.getAttribute('data-chatgpt-backdrop-reading') === 'prior-reading');
    test('Restore preserves native Accent controls bubbles and original preference attributes', accentMatchesNative() && JSON.stringify(accentPaint('accent-thread-send')) === JSON.stringify(initialAccentPaint) && document.documentElement.getAttribute('class') === nativeAccentClass && document.documentElement.getAttribute('data-fixture-accent') === nativeAccentAttribute);
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
    test('Restore returns the native settings page and preserves every card control and footer', getComputedStyle(settingsLayout).backgroundColor === settingsNative.layoutBackground && getComputedStyle(settingsCard).backgroundColor === settingsNative.cardBackground && getComputedStyle(settingsPreview).backgroundColor === settingsNative.previewBackground && getComputedStyle(settingsFooter).backgroundColor === settingsNative.footerBackground && settingsInput.value === 'Original setting');
    test('Restore returns all current module paint and guard fixtures exactly', [...moduleNativeIDs, ...moduleGuardIDs].every(id => JSON.stringify(modulePaint(id)) === JSON.stringify(moduleBefore[id])));
    test('restore returns the native Dots header gradient and its original geometry', getComputedStyle(dotsHeaderFade).backgroundImage === dotsHeaderNative.fadeImage && JSON.stringify(dotsHeaderGeometry(dotsHeaderFade)) === JSON.stringify(dotsHeaderNative.fade));
    test('restore returns Dots native page footer and border paint', dotsNodes.every(node => getComputedStyle(node).backgroundColor === dotsNative.rootBackground) && !decorationAbsent(document.getElementById('dots-footer-combined')) && getComputedStyle(document.getElementById('dots-disclaimer')).backgroundColor === dotsNative.rootBackground && getComputedStyle(dotsWrap).borderBottomColor === dotsNative.rootBackground && getComputedStyle(dotsWrap).borderBottomWidth === dotsNative.borderWidth);
    test('restores pre-existing marker attributes', document.documentElement.getAttribute('data-chatgpt-backdrop') === 'prior-root' && old.getAttribute('data-chatgpt-backdrop-surface') === 'prior-main');
    test('restore is repeatable', api.restore().restored === true);
    const restoredDocument = document.documentElement.outerHTML;
    const restoredSettingsAncestorClass = settingsAncestor.getAttribute('class');
    settingsAncestor.classList.add('settings-visibility-hidden'); await wait();
    if (restoredSettingsAncestorClass === null) settingsAncestor.removeAttribute('class'); else settingsAncestor.setAttribute('class', restoredSettingsAncestorClass);
    await wait();
    test('settings visibility changes after Restore cannot reactivate styling or mutate the restored document', document.documentElement.outerHTML === restoredDocument && !document.querySelector('[data-chatgpt-backdrop-layer]') && getComputedStyle(settingsLayout).backgroundColor === settingsNative.layoutBackground);
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
    return {engineVersion: api.version, passed: checks.filter(check => check.pass).length, total: checks.length, settleTimeouts, focusDiagnostic, sidebarDiagnostic, titlebarCapDiagnostic, bottomGapDiagnostic, workSurfaceDiagnostic, dotsDiagnostic, dotsHeaderDiagnostic, settingsDiagnostic, readingDiagnostic, dotsReadingDiagnostic, restoreDiagnostic, gifDiagnostic, gifSupported, checks};
    """#
}
