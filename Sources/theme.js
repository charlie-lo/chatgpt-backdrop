/* ChatGPT Backdrop — original, local-only visual styling engine. */
(() => {
  "use strict";

  const VERSION = "1.1.2";
  const GLOBAL = "__chatGPTBackdrop";
  const ROOT_ATTRIBUTE = "data-chatgpt-backdrop";
  const SURFACE_ATTRIBUTE = "data-chatgpt-backdrop-surface";
  const MUTED_ATTRIBUTE = "data-chatgpt-backdrop-muted";
  const MAX_DATA_LENGTH = 20 * 1024 * 1024;
  const owner = "cgb-" + Math.random().toString(36).slice(2);
  const previousEngine = globalThis[GLOBAL];
  if (previousEngine && previousEngine.version === VERSION &&
      typeof previousEngine.apply === "function") return previousEngine.status();
  if (previousEngine && typeof previousEngine.restore === "function") previousEngine.restore();

  let config = null;
  let layer = null;
  let image = null;
  let shade = null;
  let stylesheet = null;
  let appliedImageData = null;
  let treeObserver = null;
  let themeObserver = null;
  const colorScheme = matchMedia("(prefers-color-scheme: dark)");
  let frame = 0;
  let active = false;
  let waitingForDocument = false;
  let mode = "dark";
  let originalRootAttribute = null;
  let originalMutedAttribute = null;
  const marked = new Map();

  const nativeSurfaces = [
    "[data-app-shell-page-surface]",
    "[data-app-shell-main-surface]",
    "[data-app-shell-main-content-layout]",
    "[data-app-shell-workspace-row]",
    "[data-app-shell-page-sidebar]",
    'aside.app-shell-left-panel[data-app-shell-left-panel-appearance]',
    'aside.app-shell-left-panel [data-app-shell-left-panel-appearance]',
    'aside.app-shell-left-panel .sidebar-navigation',
    "[data-app-shell-titlebar]",
    '[data-thread-scroll-footer="true"]',
    'form[data-chatgpt-composer]',
    "main",
    '[role="main"]',
    '[data-testid="conversation-turns"]',
    "#thread",
    "#thread-bottom-container"
  ].join(",");
  const protectedSurface = [
    "dialog", '[role="dialog"]', '[role="alertdialog"]',
    '[role="menu"]', '[role="listbox"]', "pre", "code", "iframe",
    '[data-testid="settings-modal"]', '[data-settings-page]'
  ].join(",");

  function number(value, fallback, minimum, maximum) {
    return typeof value === "number" && Number.isFinite(value)
      ? Math.min(maximum, Math.max(minimum, value)) : fallback;
  }

  function normalize(input) {
    if (!input || typeof input !== "object") throw new Error("Background settings must be an object.");
    const data = input.imageData;
    if (typeof data !== "string" || data.length > MAX_DATA_LENGTH) {
      throw new Error("Choose local image data smaller than 20 MB.");
    }
    const match = /^data:image\/(png|jpeg|webp|gif);base64,([A-Za-z0-9+/]+={0,2})$/.exec(data);
    if (!match || match[2].length % 4 !== 0) throw new Error("Only local PNG, JPEG, WebP, or GIF image data is supported.");
    let signature;
    try { signature = atob(match[2].slice(0, 40)); }
    catch (_) { throw new Error("The image data has invalid Base64 encoding."); }
    const valid = match[1] === "png"
      ? signature.slice(0, 8) === "\x89PNG\r\n\x1a\n"
      : match[1] === "jpeg"
        ? signature.charCodeAt(0) === 255 && signature.charCodeAt(1) === 216 && signature.charCodeAt(2) === 255
        : match[1] === "gif"
          ? signature.slice(0, 6) === "GIF87a" || signature.slice(0, 6) === "GIF89a"
          : signature.slice(0, 4) === "RIFF" && signature.slice(8, 12) === "WEBP";
    if (!valid) throw new Error("The image contents do not match the declared format.");
    const position = input.position && typeof input.position === "object" ? input.position : {};
    return {
      imageData: data,
      opacity: number(input.opacity, 0.5, 0, 0.85),
      blur: number(input.blur, 0, 0, 24),
      panelOpacity: number(input.panelOpacity, 0.68, 0, 1),
      x: number(position.x ?? input.x ?? input.positionX, 50, 0, 100),
      y: number(position.y ?? input.y ?? input.positionY, 50, 0, 100),
      imageBytes: Math.floor(match[2].length * 3 / 4) - (match[2].endsWith("==") ? 2 : match[2].endsWith("=") ? 1 : 0)
    };
  }

  function isMutedRoute() {
    return /(?:^|\/)(?:settings|login|auth|oauth|billing|checkout)(?:\/|$)/i.test(location.pathname);
  }

  function detectMode() {
    const root = document.documentElement;
    if (root.classList.contains("dark") || root.getAttribute("data-theme") === "dark") return "dark";
    if (root.classList.contains("light") || root.getAttribute("data-theme") === "light") return "light";
    const scheme = getComputedStyle(root).colorScheme;
    if (scheme === "dark" || scheme === "light") return scheme;
    const rgb = getComputedStyle(document.body || root).color.match(/[\d.]+/g);
    if (rgb && rgb.length >= 3) {
      return (Number(rgb[0]) * 0.2126 + Number(rgb[1]) * 0.7152 + Number(rgb[2]) * 0.0722) > 140 ? "dark" : "light";
    }
    return colorScheme.matches ? "dark" : "light";
  }

  function mark(node) {
    if (!(node instanceof Element) || node === layer || node === stylesheet ||
        node.closest(protectedSurface)) return;
    if (!marked.has(node)) marked.set(node, node.getAttribute(SURFACE_ATTRIBUTE));
    if (node.getAttribute(SURFACE_ATTRIBUTE) !== owner) node.setAttribute(SURFACE_ATTRIBUTE, owner);
  }

  function unmark(node, previous) {
    if (node.getAttribute(SURFACE_ATTRIBUTE) !== owner) return;
    if (previous === null) node.removeAttribute(SURFACE_ATTRIBUTE);
    else node.setAttribute(SURFACE_ATTRIBUTE, previous);
  }

  function releaseMarks() {
    for (const [node, previous] of marked) unmark(node, previous);
    marked.clear();
  }

  function syncSurfaces() {
    if (!active || !document.body) return;
    const muted = isMutedRoute();
    if (muted) {
      if (document.documentElement.getAttribute(MUTED_ATTRIBUTE) !== owner) {
        document.documentElement.setAttribute(MUTED_ATTRIBUTE, owner);
      }
      releaseMarks();
    } else {
      if (document.documentElement.getAttribute(MUTED_ATTRIBUTE) === owner) {
        if (originalMutedAttribute === null) document.documentElement.removeAttribute(MUTED_ATTRIBUTE);
        else document.documentElement.setAttribute(MUTED_ATTRIBUTE, originalMutedAttribute);
      }
      // Mark only known layout surfaces and their ancestor chain. Never traverse
      // into messages, code editors, dialogs, or unrelated document previews.
      const wanted = new Set();
      for (const surface of document.querySelectorAll(nativeSurfaces)) {
        if (surface.closest(protectedSurface)) continue;
        let node = surface;
        for (let depth = 0; node && node !== document.body && depth < 18; depth++, node = node.parentElement) {
          if (node.closest(protectedSurface)) break;
          wanted.add(node);
        }
      }
      // A new-chat view may have no main landmark yet. Only recognize the app's
      // ordinary single root mount, never blanket-style all body descendants.
      for (const root of document.querySelectorAll("body > #root, body > #app, body > #__next")) wanted.add(root);
      for (const [node, previous] of marked) {
        if (!wanted.has(node) || !node.isConnected) { unmark(node, previous); marked.delete(node); }
      }
      for (const node of wanted) mark(node);
    }
    const nextMode = detectMode();
    if (mode !== nextMode) { mode = nextMode; updateOwnedStyles(); }
    if (layer && !layer.isConnected) document.body.prepend(layer);
    if (stylesheet && !stylesheet.isConnected) (document.head || document.documentElement).append(stylesheet);
  }

  function scheduleSync() {
    if (!active || frame) return;
    frame = requestAnimationFrame(() => { frame = 0; syncSurfaces(); });
  }

  function updateOwnedStyles() {
    if (!config || !layer || !stylesheet) return;
    const root = `html[${ROOT_ATTRIBUTE}="${owner}"]:not([${MUTED_ATTRIBUTE}="${owner}"])`;
    const outsideProtected = ":not(:is(dialog,dialog *,[role=dialog],[role=dialog] *,[role=alertdialog],[role=alertdialog] *,[role=menu],[role=menu] *,[role=listbox],[role=listbox] *,pre,pre *,code,code *))";
    const composer = '[class*="_ComposerLayoutRoot_"]:is([data-composer-surface-variant="default"],[data-composer-surface-variant="opaque"],[data-composer-surface-variant="secondary"])';
    const decorativeBackground = 'div[aria-hidden="true"][class*="_background_"]:is([class*="_surface_"],[class*="_fade_"],[class*="_combined_"]):empty';
    const panel = mode === "light" ? "255,255,255" : "24,24,27";
    const veil = mode === "light" ? "255,255,255" : "0,0,0";
    // Keep the existing decoded image and animation timeline when only the
    // controls or native light/dark mode change. A new URL starts a new image.
    if (appliedImageData !== config.imageData) {
      image.style.backgroundImage = `url("${config.imageData}")`;
      appliedImageData = config.imageData;
    }
    image.style.backgroundPosition = `${config.x}% ${config.y}%`;
    image.style.filter = config.blur > 0 ? `blur(${config.blur}px)` : "none";
    image.style.inset = config.blur > 0 ? `-${Math.ceil(config.blur * 2)}px` : "0";
    shade.style.backgroundColor = `rgba(${veil},${config.opacity})`;
    stylesheet.textContent = `
${root} { background-color: ${mode === "light" ? "#f5f5f5" : "#18181b"} !important; }
${root} body { background-color: transparent !important; isolation: isolate; }
${root} [${SURFACE_ATTRIBUTE}="${owner}"] {
  background-color: transparent !important;
  background-image: none !important;
}
/* Native PageSurfaceLayout reserves a spacing unit below its flex workspace.
   Remove that outer gutter so the panel's own tint reaches the window bottom.
   Keep this independent of page-sidebar, which changes during sidebar collapse. */
${root} [data-app-shell-frame][data-app-shell-page-surface="true"]${outsideProtected} {
  padding-block-end: 0 !important;
}
/* page-sidebar labels the whole page, not the sidebar. Paint exactly one
   physical sidebar; nested navigation and floating headers stay transparent. */
${root} aside.app-shell-left-panel[data-app-shell-left-panel-appearance]${outsideProtected} {
  background-color: rgba(${panel},${config.panelOpacity}) !important;
}
/* Page-surface layouts put the whole left column (rail included) below the
   native titlebar. Extend only its tint upward; the fixed titlebar controls
   stay above this non-interactive cap and keep their native drag behavior. */
${root} [data-app-shell-frame][data-app-shell-page-surface="true"] aside.app-shell-left-panel[data-app-shell-left-panel-appearance]:not([data-slate-sidebar-peeking="true"])${outsideProtected}::before {
  content: "";
  position: absolute;
  left: 0;
  right: 0;
  bottom: 100%;
  height: var(--app-shell-titlebar-height, 0px);
  background-color: rgba(${panel},${config.panelOpacity}) !important;
  background-image: none !important;
  pointer-events: none;
}
${root} aside.app-shell-left-panel [data-app-shell-left-panel-appearance]${outsideProtected},
${root} aside.app-shell-left-panel .sidebar-navigation${outsideProtected} {
  background-color: transparent !important;
  background-image: none !important;
}
/* Electron extends the sidebar's inherited paint beyond its right edge by one
   corner radius (20 CSS px here). Keep its geometry and resize hit area, but
   prevent that decorative extension from becoming a second translucent band. */
${root} aside.app-shell-left-panel[data-app-shell-left-panel-appearance]:not([data-app-shell-left-panel-appearance="content-surface"])${outsideProtected}::after {
  background: transparent !important;
  background-image: none !important;
}
/* The native visual hairline is separate from the functional resize handle. */
${root} [data-app-shell-page-sidebar="true"] [class*="_MainContentLeftBorder_"]${outsideProtected} {
  border-left-color: transparent !important;
}
/* These are empty, aria-hidden native paint layers. Their containing wrappers
   also hold transcript/controls, so never hide those wrappers themselves. */
${root} [data-app-shell-main-content-top-fade] div[aria-hidden="true"][class*="_MainContentTopFade_"]:empty${outsideProtected},
${root} .thread-scroll-container ${decorativeBackground}${outsideProtected},
${root} [data-thread-footer-background] ${decorativeBackground}${outsideProtected},
${root} [data-thread-scroll-footer="true"] ${decorativeBackground}${outsideProtected} {
  background: transparent !important;
  background-image: none !important;
  box-shadow: none !important;
  filter: none !important;
  opacity: 0 !important;
  pointer-events: none !important;
}
${root} [data-thread-scroll-footer="true"]${outsideProtected} {
  background-color: transparent !important;
}
/* The page card's native shadow is a separate empty overlay beside the sidebar. */
${root} [data-app-shell-frame] div[aria-hidden="true"][class*="_PageSurface_"]:empty${outsideProtected} {
  box-shadow: none !important;
}
${root} [data-message-author-role]${outsideProtected} {
  background-color: rgba(${panel},${config.panelOpacity}) !important;
  border-radius: 14px;
}
/* Native normal composers paint their root, except on Home where only their
   body paints. Respect the slider and remove the native elevated shadow. */
${root} ${composer}${outsideProtected} {
  --color-background-composer-primary: rgba(${panel},${config.panelOpacity}) !important;
  --color-background-composer-surface: rgba(${panel},${config.panelOpacity}) !important;
  --composer-layout-surface-background: rgba(${panel},${config.panelOpacity}) !important;
  --composer-layout-surface-shadow: none !important;
  --composer-layout-surface-backdrop-filter: none !important;
}
${root} ${composer}:not([data-composer-utility-bar-variant="home"])${outsideProtected},
${root} ${composer}[data-composer-utility-bar-variant="home"] [class*="_ComposerLayoutBody_"]${outsideProtected} {
  background-color: rgba(${panel},${config.panelOpacity}) !important;
  box-shadow: none !important;
  backdrop-filter: none !important;
}
${root} ${composer}[data-composer-utility-bar-variant="home"]${outsideProtected} {
  background-color: transparent !important;
  box-shadow: none !important;
  backdrop-filter: none !important;
}
html[${ROOT_ATTRIBUTE}="${owner}"][${MUTED_ATTRIBUTE}="${owner}"] [data-chatgpt-backdrop-layer="${owner}"] { display: none !important; }
@media print { [data-chatgpt-backdrop-layer="${owner}"] { display: none !important; } }
`;
  }

  function status() {
    return {
      active,
      pending: waitingForDocument,
      mode: active && isMutedRoute() ? "paused" : mode,
      surfaceCount: marked.size,
      imageBytes: active && config ? config.imageBytes : 0,
      version: VERSION
    };
  }

  function onDocumentReady() {
    waitingForDocument = false;
    if (config) apply(config);
  }

  function apply(input) {
    const next = normalize(input); // Validate the entire payload before changing the UI.
    config = next;
    if (!document.documentElement || !document.body) {
      if (!waitingForDocument) {
        waitingForDocument = true;
        document.addEventListener("DOMContentLoaded", onDocumentReady, {once: true});
      }
      return status();
    }
    if (waitingForDocument) {
      waitingForDocument = false;
      document.removeEventListener("DOMContentLoaded", onDocumentReady);
    }
    if (!active) {
      originalRootAttribute = document.documentElement.getAttribute(ROOT_ATTRIBUTE);
      originalMutedAttribute = document.documentElement.getAttribute(MUTED_ATTRIBUTE);
      document.documentElement.setAttribute(ROOT_ATTRIBUTE, owner);
      layer = document.createElement("div");
      layer.setAttribute("data-chatgpt-backdrop-layer", owner);
      layer.setAttribute("aria-hidden", "true");
      layer.style.cssText = "position:fixed;inset:0;z-index:-1;pointer-events:none;overflow:hidden;contain:strict;";
      image = document.createElement("div");
      image.style.cssText = "position:absolute;inset:0;background-size:cover;background-repeat:no-repeat;pointer-events:none;";
      shade = document.createElement("div");
      shade.style.cssText = "position:absolute;inset:0;pointer-events:none;";
      layer.append(image, shade);
      stylesheet = document.createElement("style");
      stylesheet.setAttribute("data-chatgpt-backdrop-style", owner);
      (document.head || document.documentElement).append(stylesheet);
      document.body.prepend(layer);
      active = true;
      mode = detectMode();
      treeObserver = new MutationObserver(records => {
        // Streaming text updates do not change layout ancestry. Re-scan only
        // when elements enter or leave the tree, rather than on every token.
        if (records.some(record => [...record.addedNodes, ...record.removedNodes].some(node => node.nodeType === 1))) scheduleSync();
      });
      treeObserver.observe(document.documentElement, {childList: true, subtree: true});
      themeObserver = new MutationObserver(scheduleSync);
      themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["class", "data-theme", "style"]});
      addEventListener("popstate", scheduleSync);
      addEventListener("hashchange", scheduleSync);
      colorScheme.addEventListener("change", scheduleSync);
    }
    updateOwnedStyles();
    syncSurfaces();
    return status();
  }

  function restore() {
    active = false;
    waitingForDocument = false;
    document.removeEventListener("DOMContentLoaded", onDocumentReady);
    treeObserver?.disconnect();
    themeObserver?.disconnect();
    treeObserver = themeObserver = null;
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
    removeEventListener("popstate", scheduleSync);
    removeEventListener("hashchange", scheduleSync);
    colorScheme.removeEventListener("change", scheduleSync);
    releaseMarks();
    layer?.remove();
    stylesheet?.remove();
    const root = document.documentElement;
    if (root && root.getAttribute(ROOT_ATTRIBUTE) === owner) {
      if (originalRootAttribute === null) root.removeAttribute(ROOT_ATTRIBUTE);
      else root.setAttribute(ROOT_ATTRIBUTE, originalRootAttribute);
    }
    if (root && root.getAttribute(MUTED_ATTRIBUTE) === owner) {
      if (originalMutedAttribute === null) root.removeAttribute(MUTED_ATTRIBUTE);
      else root.setAttribute(MUTED_ATTRIBUTE, originalMutedAttribute);
    }
    layer = image = shade = stylesheet = null;
    appliedImageData = null;
    config = null;
    return {active: false, restored: true, version: VERSION};
  }

  globalThis[GLOBAL] = Object.freeze({version: VERSION, apply, restore, status});
  return status();
})();
