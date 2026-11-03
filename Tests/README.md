# Tests

Run tests on macOS with Xcode Command Line Tools and Python 3. No third-party packages are required.

```sh
zsh Tests/run.sh --offline  # URL and endpoint validation
zsh Tests/run.sh            # Isolated CDP mock on 127.0.0.1
zsh Tests/run-media.sh      # GIF preservation and static image decoding
zsh Tests/run-theme.sh      # In-memory WebKit fixture and animation snapshots
zsh Tests/run-windows.sh    # Offline multiwindow discovery, updates and cleanup
```

These tests do not connect to, restart, or modify ChatGPT. The mock server uses a temporary local port; the scripts remove their temporary build output and fixtures.

## Multiwindow controller tests

`run-windows.sh` uses in-memory discovery and transport fakes, so it needs no network or GUI access. It covers existing and newly opened chat windows, settings propagation, preserving another window after the original closes, and best-effort cleanup of every window. Unchanged discovery does not evaluate a theme again; a new WebSocket session receives fresh reload-script registration rather than reusing a stale identifier.

The multiwindow suite passed **117/117 checks**, including settings staged while all chat windows are closed and ensuring Restore cannot be undone by later discovery.

The suite also checks temporary discovery failures, partial application failures, lost registration replies, restore after reconnect, explicit reset after a confirmed app restart, and strict exclusion of browser, utility, untrusted-origin and non-page targets. Apply and Restore share the same document guard so a target that navigates between discovery and cleanup is not styled as a chat window.

## Recorded release validation

The 1.1.4 Dots fix passed **128/128** isolated native WebKit checks. The same fixture against 1.1.1 failed ten Dots background assertions and passed the other 118 checks. Coverage includes both nested embedded messaging shells and panes, footer paint and decorative fades, initial rendering and SPA navigation, zero/full opacity, light/dark mode, unchanged message bubbles/reactions/attachments, protected layouts, pointer hit testing, focus, scrolling and exact document restoration. Native GIF snapshots showed all three frames before and after control changes. The app builds as 1.1.4 (build 8), its bundled theme matches the tested source and its ad hoc signature verifies.

The 1.1.1 release passed 99 isolated native WebKit checks, covering the titlebar tint, sidebar resizing, native controls, exact restoration, and GIF playback. Prior validation also passed 12 media checks and 17 CDP transport checks. Native GIF preview was verified using three rendered frame colors, including continuity during SwiftUI control updates. The app UI was checked for GIF selection, theme export/import and the new logo.

The theme fixture models the installed app's relevant DOM and paint rules. It checks panel transparency and decorative shadows while preserving code, menus, document composers, focus behavior and resize hit areas. It also samples real GIF frames before and after control changes.

Generated result JSON, local process diagnostics, compiled test apps and scratch assets are intentionally excluded from Git. They are not needed to build or run the test suites.

## Native GUI requirements

The theme harness creates its own visible accessory window so animation frames and real focus states can run. WebKit needs its normal macOS helper services. Some restricted shells block these services; run the script in an ordinary macOS terminal if WebKit cannot start.

`MediaPreviewTests.swift` is an additional native animated-preview harness used during development. Its app bundle supplies an original test GIF as `animation.gif`; it never reads user-selected images.
