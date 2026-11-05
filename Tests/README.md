# Tests

Run tests on macOS with Xcode Command Line Tools and Python 3. No third-party packages are required.

```sh
zsh Tests/run.sh --offline  # URL and endpoint validation
zsh Tests/run.sh            # Isolated CDP mock on 127.0.0.1
zsh Tests/run-media.sh      # GIF preservation and static image decoding
zsh Tests/run-theme.sh      # In-memory WebKit fixture and animation snapshots
zsh Tests/run-windows.sh    # Offline multiwindow discovery, updates and cleanup
zsh Tests/run-settings.sh   # Theme compatibility and reading-mode serialization
node --test .github/scripts/codex-gate.test.cjs # Automatic merge policy
```

These tests do not connect to, restart, or modify ChatGPT. The mock server uses a temporary local port; the scripts remove their temporary build output and fixtures.

Reading performance checks use a warmed long-conversation fixture and count native rectangle/style reads and owned plate writes during controlled scrolling. These deterministic work counters validate reduced update work without relying on machine-specific timing. They do not measure FPS or GPU compositing cost in the user's live app. The same cases retain geometry, streaming, visibility recovery, ownership repair, GIF identity and restoration checks.

The theme script runs the full suite twice: once with legacy `_Name_hash` module classes, then with the `Name-hash` classes used by ChatGPT 26.1029.61003. Run just the current format with `ThemeTests /absolute/path/to/theme.js --native-modules` when using a separately compiled harness. Only test-authored fixture tokens are converted; the engine is injected unchanged.

Dots reading-mode cases model its separate embedded messaging viewport, transcript column and assistant text parts. They cover native-backplate replacement, independent reading controls, mode transitions, scrolling and new messages while preserving user colors and interactive content. Unsupported or protected messaging views remain outside the reading treatment.

Native Accent regressions use the app's shared composer action-color tokens and class names. The fixture compares native send/stop controls, focus outlines and user-message fills across light/dark appearance and live Accent changes, including Dots-specific action colors, Panel Opacity limits, reading modes and restoration. Backdrop must style the composer surface without replacing those shared action tokens.

## Multiwindow controller tests

`run-windows.sh` uses in-memory discovery and transport fakes, so it needs no network or GUI access. It covers existing and newly opened chat windows, settings propagation, preserving another window after the original closes, and best-effort cleanup of every window. Unchanged discovery does not evaluate a theme again; a new WebSocket session receives fresh reload-script registration rather than reusing a stale identifier.

The multiwindow suite passed **117/117 checks**, including settings staged while all chat windows are closed and ensuring Restore cannot be undone by later discovery.

The suite also checks temporary discovery failures, partial application failures, lost registration replies, restore after reconnect, explicit reset after a confirmed app restart, and strict exclusion of browser, utility, untrusted-origin and non-page targets. Apply and Restore share the same document guard so a target that navigates between discovery and cleanup is not styled as a chat window.

## Recorded release validation

The Cards overscroll regression moves the native conversation column synchronously without dispatching a scroll event or waiting for a geometry update. It checks that text and Cards share the same movement at both scroll boundaries, in regular conversations and Dots. Coverage also preserves native clipping, scroll dimensions, last-row spacing, controls, opacity/blur, fixed Sheet/Focus behavior, fallback layouts and exact restoration. The fixture models the content translation; the operating system's actual trackpad rebound and visible backdrop blur still need live visual confirmation.

The final 1.2.6 compatibility fix passed **438/438 checks in each class format** (876 total), including the latest Settings background/visibility and Dots reading-mode coverage from main. The earlier compatibility fixture against 1.2.2 reproduces **36 failures** (274/310 pass), including the top gradient, page shadow, footer decorations, composer opacity, sidebar hairline and Dots header. The fixed suites preserve native Accent colors, reading modes, GIF playback and exact restoration. Guard fixtures retain similarly named components, control-bearing wrappers, dialogs and menus. CI runs both formats sequentially.

The 1.2.4 Settings visibility fix passed **361/361** isolated native WebKit checks. Already mounted Settings layouts and their ancestors automatically pause and resume the actual wallpaper when native visibility, protection or structural attributes change, without Apply, route events or DOM insertion. The same fixture against 1.2.3 reproduces 36 Settings transition failures (**325/361** pass). Checks also preserve the existing decoded image, native cards and controls, and exact restoration; attribute changes after Restore cannot reactivate styling. GIF snapshots retain all three frames before and after control changes, with no settling timeouts. The app builds as 1.2.4 (build 14), its bundled engine matches the tested source and ad hoc signing verifies.

The 1.2.3 Settings fix passed **324/324** isolated native WebKit checks after integration with the native Accent updates on main. Settings cases cover the actual page surface, native cards/controls/previews/footer, compact and light layouts, scrolling, pointer hit testing, focus, SPA mounting, route guards and exact restoration. Accent cases preserve native user-message fills, send/stop buttons and focus outlines while changing themes, opacity and reading modes. Hidden/inert cached settings, protected overlays and login/auth/billing routes remain excluded. Native GIF snapshots show all three frames before and after control changes; existing reading-mode and Dots checks also pass. The app builds as 1.2.3 (build 13), its bundled engine matches the tested source and ad hoc signing verifies. The prior 12 media tests and offline endpoint validations passed. Live appearance in ChatGPT remains to be confirmed after applying the update.

The 1.2.1 Dots header fix passed **272/272** isolated native WebKit checks after integration with the reading modes on main. The suite includes 16 added checks for the separate portaled header gradient, reproducing its native 96 CSS-pixel height, layout host and Dots anchor marker. Coverage preserves header controls, pointer hit testing, anchor geometry, unrelated/protected gradients, SPA replacement, opacity extremes, light mode, reading modes and exact document restoration. Native GIF snapshots render all three frames before and after control changes. The earlier 1.1.5 baseline reproduced the header gradient in five paint assertions. The app builds as 1.2.1 (build 11), its bundled engine matches the tested source and its ad hoc signature verifies. Live visual confirmation in ChatGPT remains separate from the isolated fixture.

The 1.1.4 Dots fix passed **128/128** isolated native WebKit checks. The same fixture against 1.1.1 failed ten Dots background assertions and passed the other 118 checks. Coverage includes both nested embedded messaging shells and panes, footer paint and decorative fades, initial rendering and SPA navigation, zero/full opacity, light/dark mode, unchanged message bubbles/reactions/attachments, protected layouts, pointer hit testing, focus, scrolling and exact document restoration. Native GIF snapshots showed all three frames before and after control changes. The app builds as 1.1.4 (build 8), its bundled theme matches the tested source and its ad hoc signature verifies.

The 1.2.0 (build 10) reading-mode changes passed **256/256** native WebKit checks in [macOS CI](https://github.com/charlie-lo/chatgpt-backdrop/actions/runs/41764525916), retaining the panel, titlebar, bottom-edge, Dots and multiwindow coverage. The settings suite passed **31/31** checks. A local sandboxed attempt could not start WebKit's content process; the graphical results come from the hosted runner.

The 1.1.1 release passed 99 isolated native WebKit checks, covering the titlebar tint, sidebar resizing, native controls, exact restoration, and GIF playback. Prior validation also passed 12 media checks and 17 CDP transport checks. Native GIF preview was verified using three rendered frame colors, including continuity during SwiftUI control updates. The app UI was checked for GIF selection, theme export/import and the new logo.

The 1.1.2 bottom-edge fix passed **111/111** isolated native WebKit checks. The same fixture against 1.1.1 failed seven bottom-coverage assertions, measuring a 4 CSS-pixel gap (8 pixels with the larger spacing token); 1.1.2 measured zero in both cases. Coverage includes the collapsed navigation rail, zero/full opacity, bottom-edge hit testing, inner footer spacing, unchanged top/right insets and corner radii, protected/non-page layouts, and exact document restoration. Native GIF snapshots still showed all three frames before and after control changes.

The theme fixture models the installed app's relevant DOM and paint rules. It checks panel transparency and decorative shadows while preserving code, menus, document composers, focus behavior and resize hit areas. It also samples real GIF frames before and after control changes.

The reading-mode fixture covers None, Sheet, Cards and Focus; independent opacity/blur, native column geometry, streaming and scrolling, hidden or collapsed tool groups, user bubbles, protected surfaces, and cleanup. The settings suite covers legacy and future theme fields, bounded reading values, and serialization of all four modes.

The reading-mode harness records whether WebKit snapshots include the backdrop-filter effect. When snapshot support is unavailable, computed CSS or unchanged snapshot variance does not establish visible blur. This diagnostic is not counted as an automated passing assertion; visible local blur still needs confirmation in a graphical session.

Generated result JSON, local process diagnostics, compiled test apps and scratch assets are intentionally excluded from Git. They are not needed to build or run the test suites.

The 1.1.3 work-mode surface fix passed **133/133** isolated native WebKit checks. New cases cover the environment pill, attached project/device rail, styled summary and dynamic-isle variants, nested sticky heading fills, zero/full/intermediate opacity, light/dark mode, native controls, protected contexts, and exact restoration. Floating rails, unstyled summaries and item states retain their native paint. With the same fixture, 1.1.2 leaves all three filled roots at alpha 1 when the requested alpha is 0.1866; 1.1.3 applies the requested tint and clears the headings' duplicate fill. GIF snapshots still render all three frames before and after control changes.

Pull requests run the macOS suites in CI. See the [Codex review and automatic merge policy](../.github/AUTOMATION.md) for the checks and review gate required before automatic merging.

## Native GUI requirements

The theme harness creates its own visible accessory window so animation frames and real focus states can run. WebKit needs its normal macOS helper services. Some restricted shells block these services; run the script in an ordinary macOS terminal if WebKit cannot start.

`MediaPreviewTests.swift` is an additional native animated-preview harness used during development. Its app bundle supplies an original test GIF as `animation.gif`; it never reads user-selected images.
