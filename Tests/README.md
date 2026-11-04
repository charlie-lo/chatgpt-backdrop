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

## Multiwindow controller tests

`run-windows.sh` uses in-memory discovery and transport fakes, so it needs no network or GUI access. It covers existing and newly opened chat windows, settings propagation, preserving another window after the original closes, and best-effort cleanup of every window. Unchanged discovery does not evaluate a theme again; a new WebSocket session receives fresh reload-script registration rather than reusing a stale identifier.

The multiwindow suite passed **117/117 checks**, including settings staged while all chat windows are closed and ensuring Restore cannot be undone by later discovery.

The suite also checks temporary discovery failures, partial application failures, lost registration replies, restore after reconnect, explicit reset after a confirmed app restart, and strict exclusion of browser, utility, untrusted-origin and non-page targets. Apply and Restore share the same document guard so a target that navigates between discovery and cleanup is not styled as a chat window.

## Recorded release validation

The 1.1.6 Dots header fix passed **178/178** isolated native WebKit checks, including 16 new checks for the separate portaled header gradient. The fixture reproduces its native 96 CSS-pixel height, layout host and Dots anchor marker. Coverage preserves header controls, pointer hit testing, anchor geometry, unrelated/protected gradients, SPA replacement, opacity extremes, light mode and exact restoration. Native GIF snapshots still render three frames before and after control changes. Against 1.1.5, the same fixture reproduces the gradient and fails five header-paint checks; that baseline run also recorded two unrelated focus failures while the fixture window was inactive. The fixed run passed all focus checks. The app builds as 1.1.6 (build 10), its bundled engine matches the tested source and its ad hoc signature verifies. Live visual confirmation in ChatGPT remains separate from the isolated fixture.

The 1.1.4 Dots fix passed **128/128** isolated native WebKit checks. The same fixture against 1.1.1 failed ten Dots background assertions and passed the other 118 checks. Coverage includes both nested embedded messaging shells and panes, footer paint and decorative fades, initial rendering and SPA navigation, zero/full opacity, light/dark mode, unchanged message bubbles/reactions/attachments, protected layouts, pointer hit testing, focus, scrolling and exact document restoration. Native GIF snapshots showed all three frames before and after control changes. The app builds as 1.1.4 (build 8), its bundled theme matches the tested source and its ad hoc signature verifies.

The upcoming 1.2.0 (build 10) reading-mode changes retain the existing panel, titlebar, bottom-edge, Dots and multiwindow coverage. The settings suite passed **31/31** checks during draft review. Validation of the integrated WebKit fixture is pending macOS CI; a local sandboxed attempt compiled but could not start the WebKit content process, so it produced no behavioral assertion results.

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
