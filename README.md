# ChatGPT Backdrop

![ChatGPT Backdrop logo](Brand/Backdrop-Logo-Preview.png)

An original, unofficial Mac utility for image backgrounds in the ChatGPT desktop app. **English is the default interface and documentation language.** [繁體中文說明](README.zh-TW.md)

Choose a local image, adjust its shade, blur, panel opacity and position, then restore the original appearance whenever you want.

## Version 1.2.6 — updated ChatGPT styling compatibility

Supports the CSS module names introduced in ChatGPT 26.1029.61003 while retaining the earlier naming format. This restores top-shadow removal, footer fades, composer opacity, the sidebar hairline fix and the Dots header decoration override after the app update. Apply with the updated Backdrop app to replace the previously loaded styling engine.

## Version 1.2.5 — Dots reading modes

Applies Sheet, Cards and Focus to supported Dots conversations as well as regular chats. Reading Opacity and Reading Blur control the reading treatment without stacking the native assistant text backing underneath it. User-message Accent colors, reactions, attachments and controls retain their native styling. None restores the prior appearance while keeping the wallpaper; Restore Original removes the background and all reading treatments.

## Version 1.2.4 — Settings backgrounds

The main Settings page now shows the selected wallpaper around its cards. Cards, controls, previews and the action footer keep their native appearance. Hiding or revealing an already mounted Settings page updates the wallpaper automatically. Embedded settings and protected dialogs retain their original styling; Restore Original restores the page background.

## Version 1.2.2 — native Accent colors

Preserves the native Accent color on send/stop buttons, focus outlines and user-message fills in light and dark mode. Panel Opacity changes only the composer surface; changing Accent while a background is active updates the native controls immediately. Apply with the updated app to replace an earlier styling engine.

## Version 1.2.1 — Dots header fade

Removes the separate decorative gradient below the Dots toolbar in ChatGPT build 26.1027.61615. The header buttons, profile controls and anchor positioning retain their native appearance and behavior. Restore Original returns the native gradient.

## Version 1.2.0 — reading modes

Build 10 adds optional reading treatments to the existing background controls.

Choose **Reading Mode** independently of the sidebar's Panel Opacity:

| Mode | Effect |
| --- | --- |
| **None** | Keep the existing appearance. This is the default, including for older themes. |
| **Sheet** | One continuous translucent surface behind the conversation column. |
| **Cards** | Separate surfaces behind assistant responses and tool groups. |
| **Focus** | A soft-edged central tint with no visible card outline. |

**Reading Opacity** and **Reading Blur** control only the reading treatment. Text and controls stay sharp. The treatment follows the recognized conversation viewport and its actual column width; sidebar panels, document editors, menus and embedded browsers retain their own appearance. Modes can be changed live after applying the background. Choosing None removes the reading treatment while keeping the wallpaper.

Reading settings are included in **Save Theme…** and restored by **Import Theme…**. Existing theme files remain compatible and start with None. New or unsupported views without a recognized conversation column receive no reading plate.

Open the new app to access the four-way picker. Save your theme and note **Advanced → Local Port** before quitting an older connected version. To reuse that existing debug session, enter the same port in the new app and choose **Connect**, then import the theme and apply. This avoids restarting ChatGPT; the normal restart confirmation remains available when starting a new session.

## Version 1.1.5 — combined panel coverage

Combines bottom-edge and Work-mode panel opacity fixes with Dots backgrounds and multiwindow support. The updated styling engine replaces earlier loaded versions when applying a background.

## Version 1.1.4 — Dots backgrounds

Custom backgrounds now show through the Dots page's nested messaging layout. Its footer backing and decorative fades become transparent while message bubbles, attachments, reactions and composer controls retain their native styling. Restore Original removes these overrides.

## Version 1.1.0 — animated GIFs and a new identity

- Choose a GIF as a background and play it in the native preview.
- Retains original GIF frames, timing and loop metadata through theme export/import; GIFs are not flattened into PNGs.
- Keeps GIF playback running when the same image's opacity, blur, position, or native light/dark mode changes.
- Adds a new Backdrop logo to the app icon and interface. PNG and macOS ICNS assets, plus the imagegen design prompt, are included in [Brand](Brand/README.md).
- Preserves the 1.0.2 sidebar, opacity and input-area fixes.

Open the new app to use GIF selection and animated preview. If an earlier Backdrop window is still open, save its theme and quit that version first. To reuse an already-enabled ChatGPT debug session, note its **Local Port** in the old version's Advanced section, then use **Connect** with that port in the new version before applying. Otherwise, the normal restart confirmation is available.

## Version 1.1.1 — titlebar tint

Panel Opacity now extends above the left sidebar into the native titlebar. The tint includes the navigation rail, follows sidebar resizing and uses the native titlebar height. It does not intercept button clicks or dragging. Existing GIF support and sidebar edge fixes are retained.

## Version 1.1.2 — bottom-edge coverage

Removes the native page frame's bottom gutter so Panel Opacity reaches the window bottom, including when the sidebar is collapsed to its navigation rail. The native top offset, right inset, inner footer spacing and corner radii are preserved.

## Version 1.1.3 — work-mode panel opacity

Panel Opacity now also controls the Edit environment pill, the Choose project / This computer bar, and the Outputs / Subagents / Sources summary card. Summary headings no longer add an opaque layer over the card. Floating rails, unstyled summaries, item hover states, dialogs and menus keep their native styling.

## Version 1.0.2 — remaining sidebar edge

- Clears the native inherited-background extension beyond the sidebar's right edge, which was exposed as a 20 CSS-pixel dark band.
- Clears only the main pane's visual sidebar hairline. The resize handle and its draggable hit area remain unchanged.
- Keeps the 1.0.1 fixes for panel opacity, header/footer decoration, and typing behavior.

## Version 1.0.1 — panel opacity fixes

- Applies the sidebar tint once, with transparent inner navigation and header surfaces.
- Clears only the native empty page-shadow and top/footer decoration layers, preserving the transcript and composer controls.
- Respects the requested Panel Opacity on the composer, including values below 72%. The preview now follows the same value.
- Leaves inline/document composers, dialogs, menus, code blocks, and unrelated card shadows unchanged.

## Quick start

Requires an Apple Silicon Mac with macOS 14 or later and Xcode Command Line Tools.

```sh
git clone https://github.com/charlie-lo/chatgpt-backdrop.git
cd chatgpt-backdrop
zsh build.sh
```

1. Open the generated **ChatGPT Backdrop.app**.
2. Click **Choose Background…** and select a local image or GIF, or try the included Twilight Hills sample.
3. Adjust the sliders and choose **None**, **Sheet**, **Cards**, or **Focus**. **Save Theme…** exports the image and settings together; **Import Theme…** loads them later.
4. Finish any work currently running in ChatGPT, then click **Apply Background**. **The first application asks you to restart ChatGPT, which interrupts its current work.**
5. Click **Restore Original** to remove the background. Quitting this tool also attempts to restore the appearance.

Static images are resized locally. GIFs keep their original animation data; GIF files up to 14 MB are supported within the displayed canvas/frame limits. The tool does not upload files, extract conversation text, or install an automatic startup service. Theme files contain the image itself, so choose where to store or share them.

Chats opened with **Open in New Window** receive the current background automatically, normally within two seconds. Already-open chat windows are included when you connect. Changes and **Restore Original** apply to all managed chat windows; closing the original window does not stop the remaining windows from receiving updates. Backdrop polls for new windows without reapplying an unchanged background, so normal discovery does not restart a GIF.

Rebuild and open the updated Backdrop app to enable multiwindow support. Before quitting an older Backdrop version, save its theme and note its **Local Port**. Use **Connect** with that port and import the theme in the new build to reuse the current ChatGPT session without restarting ChatGPT.

The folder includes `Twilight Hills.png` and a ready-to-import `Twilight Hills.chatgpt-background.json` sample.

## Compatibility and behavior

- The build targets **Apple Silicon Macs running macOS 14 or later**.
- Designed for `/Applications/ChatGPT.app`, bundle ID `com.openai.codex`, with styling fixtures for the module naming formats used through local build `26.1029.61003`.
- Targets primary chat windows at `app://-/index.html`, including **Open in New Window** chats. It excludes embedded browsers, other origins, the separate `detached-window.html` browser shell, and avatar, dictation, Spotlight and hotkey utility windows. Injection and restoration retain the same application-origin and top-frame guards.
- Does not modify ChatGPT's installed files, login information, or system protections.
- Keep Backdrop open while using the background. When ChatGPT exits, the injection ends; import your saved theme and apply it again next time.
- Restoring the appearance does not close the debugging port. Quit ChatGPT and reopen it normally to disable that local connection.
- ChatGPT updates can change the interface. Compatibility with every version is not guaranteed. Identity verification or connection failures stop the application and show a reason.

## Build from source

Requires Xcode Command Line Tools. Uses only macOS frameworks; no third-party packages or downloaded installers:

```sh
zsh build.sh
```

Local builds are ad hoc signed and are not Apple-notarized. Source code is in `Sources/`.

## Tests

```sh
zsh Tests/run.sh          # Test-only CDP server on 127.0.0.1
zsh Tests/run-theme.sh    # Isolated, in-memory WebKit page
zsh Tests/run-media.sh    # GIF preservation and static image decoding
zsh Tests/run-windows.sh  # Offline multiwindow discovery, updates and cleanup
zsh Tests/run-settings.sh # Older themes and reading-mode serialization
node --test .github/scripts/codex-gate.test.cjs # Automatic merge policy
```

Tests never connect to, restart, or modify ChatGPT. See [test details and results](Tests/README.md). Pull requests run the macOS suites in CI and follow the [Codex review and automatic merge policy](.github/AUTOMATION.md).

The interface, restart-confirmation cancellation, local transport and isolated styling engine have been tested. The regression fixture models the installed app's native sidebar extension, resize handle, shadow and composer structure. Direct inspection of the protected ChatGPT window was unavailable to the agent, so visual confirmation in your live session remains yours to check after applying the update.

## Implementation

Built with SwiftUI, AppKit, URLSession and original JavaScript. A local Chrome DevTools Protocol session applies removable styles. No implementation was copied from another skinning project.

- [Electron remote debugging switch](https://www.electronjs.org/docs/latest/api/command-line-switches#--remote-debugging-portport)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [Apple Code Signing](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

Source code is available under the [MIT License](LICENSE).
