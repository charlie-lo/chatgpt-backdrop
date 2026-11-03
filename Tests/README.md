# Tests

Run tests on macOS with Xcode Command Line Tools and Python 3. No third-party packages are required.

```sh
zsh Tests/run.sh --offline  # URL and endpoint validation
zsh Tests/run.sh            # Isolated CDP mock on 127.0.0.1
zsh Tests/run-media.sh      # GIF preservation and static image decoding
zsh Tests/run-theme.sh      # In-memory WebKit fixture and animation snapshots
zsh Tests/run-settings.sh   # Theme compatibility and reading-mode serialization
```

These tests do not connect to, restart, or modify ChatGPT. The mock server uses a temporary local port; the scripts remove their temporary build output and fixtures.

## Recorded release validation

The 1.2.0 release passed **189/189** isolated native WebKit assertions and **31/31** settings checks. This retains the earlier panel/titlebar/bottom-edge coverage and adds all four reading modes, independent controls, scrolling/streaming geometry, hidden and collapsed groups, native focus, text selection, links, buttons, protected surfaces, and exact restoration. GIF snapshots showed all three frames both before and after control changes. The English native picker and illustrative preview were also checked in a separate, disconnected controller build.

The 1.1.1 release passed 99 isolated native WebKit checks, covering the titlebar tint, sidebar resizing, native controls, exact restoration, and GIF playback. Prior validation also passed 12 media checks and 17 CDP transport checks. Native GIF preview was verified using three rendered frame colors, including continuity during SwiftUI control updates. The app UI was checked for GIF selection, theme export/import and the new logo.

The 1.1.2 bottom-edge fix passed **111/111** isolated native WebKit checks. The same fixture against 1.1.1 failed seven bottom-coverage assertions, measuring a 4 CSS-pixel gap (8 pixels with the larger spacing token); 1.1.2 measured zero in both cases. Coverage includes the collapsed navigation rail, zero/full opacity, bottom-edge hit testing, inner footer spacing, unchanged top/right insets and corner radii, protected/non-page layouts, and exact document restoration. Native GIF snapshots still showed all three frames before and after control changes.

The theme fixture models the installed app's relevant DOM and paint rules. It checks panel transparency and decorative shadows while preserving code, menus, document composers, focus behavior and resize hit areas. It also samples real GIF frames before and after control changes.

The reading-mode fixture covers None, Sheet, Cards and Focus; independent opacity/blur, native column geometry, streaming and scrolling, hidden or collapsed tool groups, user bubbles, protected surfaces, and cleanup. The settings suite covers legacy and future theme fields, bounded reading values, and serialization of all four modes.

On the validation machine, WebKit's snapshot API omitted the displayed backdrop-filter effect, including in a full-viewport snapshot with independently calibrated sample coordinates. The harness records that limitation as a diagnostic, rather than treating computed CSS or unchanged snapshot variance as proof of visible blur. A separate visible fixture using the production engine was checked manually: switching Reading Blur between 0 and 16 flattened only the bounded column's checkerboard, kept the surrounding wallpaper sharp, and preserved sharp text. Snapshot backdrop-filter support is not counted as an automated passing assertion.

Generated result JSON, local process diagnostics, compiled test apps and scratch assets are intentionally excluded from Git. They are not needed to build or run the test suites.

## Native GUI requirements

The theme harness creates its own visible accessory window so animation frames and real focus states can run. WebKit needs its normal macOS helper services. Some restricted shells block these services; run the script in an ordinary macOS terminal if WebKit cannot start.

`MediaPreviewTests.swift` is an additional native animated-preview harness used during development. Its app bundle supplies an original test GIF as `animation.gif`; it never reads user-selected images.
