# Development

Build with `zsh build.sh` on an Apple Silicon Mac. Run `zsh Tests/run.sh`,
`zsh Tests/run-media.sh`, and `zsh Tests/run-theme.sh` for the isolated test suites.
The theme suite needs a normal macOS graphical session and WebKit helper services.
Test merge automation with `node --test .github/scripts/codex-gate.test.cjs`.

## Code Review Rules

### Local connection and consent

- Preserve loopback-only CDP connections, target identity verification, and the
  explicit confirmation before restarting ChatGPT. Reject changes that bypass
  those checks; use the isolated mock server for connection tests.

### Styling and restoration

- Scope styling to the intended main app window, preserve native controls and
  text input, and restore the original appearance exactly. Keep unrelated
  dialogs, editors, and embedded browsers outside the styling scope.

### Media preservation

- Preserve original GIF animation data, timing, and loop metadata through theme
  import/export. Keep the existing decoding and size limits rather than silently
  flattening animations or accepting unbounded media.
