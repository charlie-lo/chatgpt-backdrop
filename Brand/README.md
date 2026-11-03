# ChatGPT Backdrop identity

Original app icon generated with the built-in `image_gen` tool in transparent-background mode. The image is intended as the independent Backdrop utility's own identity, not as an OpenAI logo.

The mark combines a mint conversation window with layered twilight scenery and a warm moon, tying the app's background feature to its chat context.

## Assets

- `Backdrop-AppIcon-original.png` — selected generated artwork, 1254 × 1254 RGBA.
- `Backdrop-AppIcon.png` — app-ready 1024 × 1024 PNG, with real transparent outside corners.
- `Backdrop.icns` — native macOS icon container, including 16–1024 px and Retina representations.

Transparency was verified across the full alpha range (0–255); all four corner pixels are fully transparent. The design was also inspected at 128 px for small-size legibility. macOS `sips` recognizes and decodes the ICNS container at 1024 px.

To rebuild only the deterministic icon packaging:

```sh
python3 Brand/package-icon.py
```

## Final prompt

```
Use case: logo-brand.
Asset type: a single production-ready square macOS app icon for an independent local utility named ChatGPT Backdrop.
Primary request: design an original, distinctive emblem that unites layered scenery/backgrounds with a subtle conversation-window silhouette.
Style: refined geometric vector-like artwork, bold clean silhouette, carefully balanced negative space, premium restrained macOS icon finish, crisp edges, legible at 32 pixels.
Composition: one centered icon only, straight-on. A dark midnight navy rounded-square tile with generous rounded corners; outside the tile is genuinely transparent. Inside, a simple mint-teal rounded conversation/window frame with a small subtle lower-right speech tail contains two flowing layered landscape shapes and one small warm peach moon. Keep the central emblem bold, simple, and uncrowded. Very subtle layered depth is acceptable, but no perspective.
Palette: midnight navy #0e1117, mint teal #64d4c2, subdued blue-teal landscape layers, a small warm peach accent. Strong contrast and an elegant quiet mood.
Text: none.
Constraints: exactly one app icon, no lettering, no words, no watermark, no presentation board, no grid, no mockup, no interface screenshot, no white canvas, no cast shadow outside the tile, no OpenAI knot or any existing brand logo. The output is the actual usable icon artwork. Preserve transparent pixels outside the rounded tile.
```

Only deterministic icon-format resizing and ICNS packaging are applied after generation. The generated artwork and alpha channel are otherwise preserved.
