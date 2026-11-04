/* ChatGPT Backdrop — original, local-only visual styling engine. */
(() => {
  "use strict";

  const VERSION = "1.2.6";
  const GLOBAL = "__chatGPTBackdrop";
  const ROOT_ATTRIBUTE = "data-chatgpt-backdrop";
  const SURFACE_ATTRIBUTE = "data-chatgpt-backdrop-surface";
  const MUTED_ATTRIBUTE = "data-chatgpt-backdrop-muted";
  const READING_ATTRIBUTE = "data-chatgpt-backdrop-reading";
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
  let settingsVisibilityObserver = null;
  let settingsObservedNodes = new Set();
  let settingsCandidates = new Set();
  const colorScheme = matchMedia("(prefers-color-scheme: dark)");
  let frame = 0;
  let active = false;
  let waitingForDocument = false;
  let mode = "dark";
  let originalRootAttribute = null;
  let originalMutedAttribute = null;
  const marked = new Map();
  const readingScopes = new Map();
  const readingPlates = new Map();
  let readingRegions = [];
  let readingCandidates = [];
  let readingVisibilityCache = new Map();
  let readingResizeObserver = null;
  let readingGeometryObserver = null;
  let readingObservedNodes = new Set();
  let readingGeometryFrame = 0;
  let readingEventsAttached = false;

  const settingsPageContent = 'div[class~="group/settings"][data-density]';
  const settingsPageSurface = `[data-app-shell-main-surface] div[class~="electron:bg-surface"]:has(> div.scrollbar-stable > ${settingsPageContent})`;
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
    // Main Settings has a separate native page fill. Its cards and previews
    // live inside settingsPageContent and retain their original appearance.
    settingsPageSurface,
    // Dots nests an embedded messaging view inside its own embedded shell.
    // Both roots and their direct panes have independent native solid fills.
    ".messaging-root.messaging-embedded",
    ".messaging-root.messaging-embedded > .thread-pane",
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
    '[data-testid="settings-modal"]', '[data-settings-page]', settingsPageContent
  ].join(",");
  const dotsReadingExcluded = '.messaging-attachments,.messaging-root:not(.messaging-embedded),.reply-chain-panel,.reply-chain-transcript';

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
      readingMode: ["none", "sheet", "cards", "focus"].includes(input.readingMode) ? input.readingMode : "none",
      readingOpacity: number(input.readingOpacity, 0.60, 0, 1),
      readingBlur: number(input.readingBlur, 8, 0, 24),
      x: number(position.x ?? input.x ?? input.positionX, 50, 0, 100),
      y: number(position.y ?? input.y ?? input.positionY, 50, 0, 100),
      imageBytes: Math.floor(match[2].length * 3 / 4) - (match[2].endsWith("==") ? 2 : match[2].endsWith("=") ? 1 : 0)
    };
  }

  function isMutedRoute() {
    if (/(?:^|\/)(?:login|auth|oauth|billing|checkout)(?:\/|$)/i.test(location.pathname)) return true;
    if (!/(?:^|\/)settings(?:\/|$)/i.test(location.pathname)) return false;
    // Native routing can be memory-backed. Recognize the page by its layout,
    // while unknown settings views and protected overlays remain excluded.
    return !Array.from(document.querySelectorAll(settingsPageSurface))
      .some(node => {
        if (node.closest(protectedSurface + ',[hidden],[inert],[aria-hidden="true"]') ||
            node.getClientRects().length === 0) return false;
        const visibility = getComputedStyle(node).visibility;
        return visibility !== "hidden" && visibility !== "collapse";
      });
  }

  function observeSettingsVisibility() {
    // Cached Settings layouts can be revealed using only native attributes.
    // Watch their own ancestor chains, including while the route is paused,
    // without observing class/style churn throughout messages and composers.
    settingsCandidates = new Set([
      ...settingsCandidates,
      ...document.querySelectorAll(settingsPageContent)
    ].filter(node => node.isConnected));
    const wanted = new Set();
    for (const candidate of settingsCandidates) {
      // Keep a connected candidate observed if its structural markers are
      // temporarily removed; restoring those markers must also resynchronize.
      for (let node = candidate; node; node = node.parentElement) wanted.add(node);
    }
    if (wanted.size === settingsObservedNodes.size &&
        [...wanted].every(node => settingsObservedNodes.has(node))) return;
    settingsVisibilityObserver?.disconnect();
    settingsVisibilityObserver = wanted.size ? new MutationObserver(scheduleSync) : null;
    for (const node of wanted) {
      settingsVisibilityObserver.observe(node, {
        attributes: true,
        attributeFilter: ["class", "style", "hidden", "inert", "aria-hidden", "role",
          "data-density", "data-app-shell-main-surface", "data-testid", "data-settings-page"]
      });
    }
    settingsObservedNodes = wanted;
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

  function restoreReadingScope(node, previous) {
    if (!node.getAttribute(READING_ATTRIBUTE)?.startsWith(owner + ":")) return;
    if (previous === null) node.removeAttribute(READING_ATTRIBUTE);
    else node.setAttribute(READING_ATTRIBUTE, previous);
  }

  function clearReading() {
    readingResizeObserver?.disconnect();
    readingGeometryObserver?.disconnect();
    readingResizeObserver = readingGeometryObserver = null;
    readingObservedNodes.clear();
    if (readingGeometryFrame) cancelAnimationFrame(readingGeometryFrame);
    readingGeometryFrame = 0;
    if (readingEventsAttached) {
      removeEventListener("resize", scheduleReadingGeometry);
      removeEventListener("scroll", onReadingScroll, true);
      readingEventsAttached = false;
    }
    for (const record of readingPlates.values()) record.element.remove();
    readingPlates.clear();
    for (const [node, previous] of readingScopes) restoreReadingScope(node, previous);
    readingScopes.clear();
    readingRegions = [];
    readingCandidates = [];
    readingVisibilityCache.clear();
  }

  function isReadingStructure(node) {
    return node instanceof HTMLElement && node.isConnected &&
      !node.closest(protectedSurface + ',aside,.app-shell-left-panel');
  }

  function isPaintedReadingAncestor(node) {
    if (!(node instanceof Element)) return true;
    if (readingVisibilityCache.has(node)) return readingVisibilityCache.get(node);
    const style = getComputedStyle(node);
    const painted = style.display !== "none" && style.visibility !== "hidden" && style.visibility !== "collapse" &&
      Number(style.opacity) !== 0 && isPaintedReadingAncestor(node.parentElement);
    readingVisibilityCache.set(node, painted);
    return painted;
  }

  function isReadingElement(node) {
    return isReadingStructure(node) && !node.closest('[hidden],[inert],[aria-hidden="true"]') && isPaintedReadingAncestor(node);
  }

  function isUserUnit(node) {
    // Search wrappers may be absent in local turns; the desktop user-message
    // renderer still emits its named group on the native bubble container.
    const selector = '[data-local-conversation-user-anchor],[data-message-author-role="user"],[class~="group/user-message"]';
    return !!node.closest(selector) || !!node.querySelector(selector);
  }

  function readingCardCandidates(column) {
    // The desktop renderer uses search-unit wrappers for assistant responses and
    // tool groups. Explicit user anchors/bubbles are never card targets.
    const candidates = new Set([...column.querySelectorAll(
      '[data-content-search-unit-key],[data-chatgpt-search-unit-key],[data-message-author-role="assistant"]'
    )].filter(node => isReadingStructure(node) && !isUserUnit(node)));
    // Local turns can omit search-unit wrappers for grouped agent activity.
    // Their renderer exposes a turn key and either one virtualized content
    // block or an immediate flex-column list of response groups. Only use that
    // verified shallow structure; never scan arbitrary nested tool/card divs.
    for (const turn of column.querySelectorAll('[data-turn-key]')) {
      const body = [...turn.children].find(node => node instanceof HTMLElement &&
        (node.hasAttribute('data-virtualized-turn-content') ||
          (node.classList.contains('flex') && node.classList.contains('flex-col'))));
      if (!body) continue;
      const groups = body.hasAttribute('data-virtualized-turn-content') ? [body] :
        [...body.children].filter(node => node instanceof HTMLElement && node.classList.contains('flex') && node.classList.contains('flex-col'));
      for (const group of groups) if (isReadingStructure(group) && !isUserUnit(group)) candidates.add(group);
    }
    return [...candidates];
  }

  function readingCardTargets(candidates, column) {
    // A display:contents/search wrapper can have no box while its nested
    // response is visible. It must not suppress that response during dedup.
    const visible = new Set(candidates.filter(node => {
      if (!isReadingElement(node)) return false;
      const box = node.getBoundingClientRect();
      return box.width > 0 && box.height > 0;
    }));
    return [...visible].filter(node => {
      for (let parent = node.parentElement; parent && parent !== column; parent = parent.parentElement) {
        if (visible.has(parent)) return false;
      }
      return true;
    });
  }

  function readingRegionCandidates() {
    const regions = [];
    for (const column of document.querySelectorAll('[data-thread-user-message-navigation-content]')) {
      const viewport = column.closest('.thread-scroll-container');
      if (isReadingStructure(column) && isReadingStructure(viewport)) {
        regions.push({column, viewport, scope: viewport, context: "thread",
          cardCandidates: config.readingMode === "cards" ? readingCardCandidates(column) : []});
      }
    }
    // Dots has its own scroll/list hierarchy and can nest two embedded shells.
    // Discover each native list once, rather than one region for each shell.
    for (const column of document.querySelectorAll('.messaging-root.messaging-embedded .message-list')) {
      if (!isReadingStructure(column) || column.closest(dotsReadingExcluded) ||
          column.parentElement?.closest('.message-list')) continue;
      const messaging = column.closest('.messaging-root');
      const scroll = column.closest('.messages-scroll');
      const viewport = scroll?.closest('.thread-pane');
      if (!messaging?.classList.contains('messaging-embedded') || !scroll ||
          !isReadingStructure(viewport) || !messaging.contains(viewport)) continue;
      const cardCandidates = config.readingMode === "cards" ? [...column.children].filter(node =>
        isReadingStructure(node) && node.matches('.message-row.assistant') &&
        [...node.querySelectorAll('[data-orbit-message-text-part],[data-markdown-text-style="assistant-message"],[data-orbit-message-block]')].some(content =>
          isReadingStructure(content) && !content.closest(dotsReadingExcluded) &&
          content.closest('.message-list') === column && content.closest('.message-row') === node)) : [];
      // The pane supplies the full height, including its absolute composer.
      // Cards still mirror the intermediate messages-scroll clipping below.
      regions.push({column, viewport, scope: column, context: "dots", cardCandidates});
    }
    return regions;
  }

  function readingClipBounds(node, viewport, visible, cache) {
    if (!node || node === viewport) return visible;
    if (cache.has(node)) return cache.get(node);
    const parent = readingClipBounds(node.parentElement, viewport, visible, cache);
    const bounds = {...parent};
    const style = getComputedStyle(node);
    // Cards live in the owned wallpaper layer, so mirror native intermediate
    // clipping without changing the response/tool wrappers themselves.
    if (style.display !== "contents") {
      const clipX = /^(hidden|clip|auto|scroll|overlay)$/.test(style.overflowX);
      const clipY = /^(hidden|clip|auto|scroll|overlay)$/.test(style.overflowY);
      if (clipX || clipY) {
        const box = node.getBoundingClientRect();
        const scaleX = node.offsetWidth > 0 ? box.width / node.offsetWidth : 1;
        const scaleY = node.offsetHeight > 0 ? box.height / node.offsetHeight : 1;
        const left = box.left + node.clientLeft * scaleX;
        const top = box.top + node.clientTop * scaleY;
        if (clipX) { bounds.left = Math.max(bounds.left, left); bounds.right = Math.min(bounds.right, left + node.clientWidth * scaleX); }
        if (clipY) { bounds.top = Math.max(bounds.top, top); bounds.bottom = Math.min(bounds.bottom, top + node.clientHeight * scaleY); }
      }
    }
    cache.set(node, bounds);
    return bounds;
  }

  function readingStyle(element, property, value) {
    if (element.style.getPropertyValue(property) !== value) element.style.setProperty(property, value);
  }

  function scheduleReadingGeometry() {
    if (!active || !config || config.readingMode === "none" || readingGeometryFrame) return;
    readingGeometryFrame = requestAnimationFrame(() => {
      readingGeometryFrame = 0;
      syncReadingGeometry();
    });
  }

  function onReadingScroll(event) {
    if (event.target === document || readingRegions.some(region =>
      event.target === region.viewport || (event.target instanceof Node && region.viewport.contains(event.target)))) {
      scheduleReadingGeometry();
    }
  }

  function observeReadingGeometry() {
    const wanted = new Set();
    for (const region of readingCandidates) {
      wanted.add(region.viewport);
      for (let node = region.column; node && node !== document.body; node = node.parentElement) wanted.add(node);
      // Keep collapsed/hidden candidates observed as well, so expanding a
      // native tool group can restore its plate without reapplying settings.
      for (const target of region.targets) {
        for (let node = target; node && node !== region.column; node = node.parentElement) wanted.add(node);
      }
    }
    const unchanged = wanted.size === readingObservedNodes.size && [...wanted].every(node => readingObservedNodes.has(node));
    if (unchanged) return;
    readingResizeObserver?.disconnect();
    readingGeometryObserver?.disconnect();
    readingResizeObserver = typeof ResizeObserver === "function" ? new ResizeObserver(() => {
      scheduleSync();
      scheduleReadingGeometry();
    }) : null;
    readingGeometryObserver = new MutationObserver(() => {
      scheduleSync();
      scheduleReadingGeometry();
    });
    for (const node of wanted) {
      readingResizeObserver?.observe(node);
      readingGeometryObserver.observe(node, {attributes: true, attributeFilter: ["style", "class", "hidden", "aria-hidden", "inert"]});
    }
    readingObservedNodes = wanted;
    if (!readingEventsAttached) {
      addEventListener("resize", scheduleReadingGeometry);
      addEventListener("scroll", onReadingScroll, true);
      readingEventsAttached = true;
    }
  }

  function syncReadingSurfaces() {
    if (!active || !config || config.readingMode === "none" || isMutedRoute()) { clearReading(); return; }
    readingVisibilityCache = new Map();
    const regions = [];
    const candidates = [];
    const wantedTargets = new Set();
    const wantedScopes = new Set();
    // This native centered wrapper supplies the real chat width. The viewport
    // supplies the vertical extent, including its sticky composer. A single
    // plate avoids stacking a transcript tint with a separate footer tint.
    for (const {column, viewport, scope, context, cardCandidates} of readingRegionCandidates()) {
      candidates.push({column, viewport, targets: cardCandidates});
      if (!isReadingElement(column) || !isReadingElement(viewport)) continue;
      const box = column.getBoundingClientRect(), view = viewport.getBoundingClientRect();
      if (box.width <= 0 || view.width <= 0 || view.height <= 0) continue;
      const targets = config.readingMode === "cards" ? readingCardTargets(cardCandidates, column) : [column];
      if (!targets.length) continue;
      regions.push({column, viewport, targets});
      wantedScopes.add(scope);
      for (const target of targets) {
        wantedTargets.add(target);
        let record = readingPlates.get(target);
        if (!record) {
          const element = document.createElement("div");
          element.setAttribute("aria-hidden", "true");
          element.setAttribute("data-chatgpt-backdrop-reading-layer", owner);
          element.style.cssText = "position:absolute;pointer-events:none;overflow:hidden;box-sizing:border-box;";
          layer.append(element);
          record = {element, target, column, viewport};
          readingPlates.set(target, record);
        }
        record.column = column; record.viewport = viewport;
        record.element.setAttribute("data-chatgpt-backdrop-reading-mode", config.readingMode);
        record.element.setAttribute("data-chatgpt-backdrop-reading-kind", config.readingMode === "cards" ? "card" : "column");
        record.element.setAttribute("data-chatgpt-backdrop-reading-context", context);
      }
    }
    for (const [target, record] of readingPlates) {
      if (!wantedTargets.has(target)) { record.element.remove(); readingPlates.delete(target); }
    }
    for (const [scope, previous] of readingScopes) {
      if (!wantedScopes.has(scope)) { restoreReadingScope(scope, previous); readingScopes.delete(scope); }
    }
    for (const scope of wantedScopes) {
      if (!readingScopes.has(scope)) readingScopes.set(scope, scope.getAttribute(READING_ATTRIBUTE));
      const value = owner + ":" + config.readingMode;
      if (scope.getAttribute(READING_ATTRIBUTE) !== value) scope.setAttribute(READING_ATTRIBUTE, value);
    }
    readingRegions = regions;
    readingCandidates = candidates;
    if (!candidates.length) { clearReading(); return; }
    observeReadingGeometry();
    syncReadingGeometry();
  }

  function syncReadingGeometry() {
    if (!active || !config || config.readingMode === "none") return;
    readingVisibilityCache = new Map();
    const panel = mode === "light" ? "255,255,255" : "24,24,27";
    const edge = mode === "light" ? "0,0,0" : "255,255,255";
    const windowWidth = document.documentElement.clientWidth || innerWidth;
    const windowHeight = document.documentElement.clientHeight || innerHeight;
    const clipBoundsCache = new Map();
    const cardSpacing = new Map();
    if (config.readingMode === "cards") {
      for (const region of readingRegions) {
        const rows = region.targets.map(target => ({target, box: target.getBoundingClientRect()})).sort((a, b) => a.box.top - b.box.top);
        rows.forEach((row, index) => {
          const previous = rows[index - 1], next = rows[index + 1];
          // Visual padding must not overlap the neighboring reading card and
          // multiply its opacity when native response groups have small gaps.
          cardSpacing.set(row.target, {
            top: previous ? Math.min(10, Math.max(0, (row.box.top - previous.box.bottom) / 2)) : 10,
            bottom: next ? Math.min(10, Math.max(0, (next.box.top - row.box.bottom) / 2)) : 10
          });
        });
      }
    }
    let refreshNeeded = false;
    for (const record of readingPlates.values()) {
      const {element, target, column, viewport} = record;
      if (!isReadingElement(column) || !isReadingElement(viewport) || !isReadingElement(target) || isMutedRoute()) {
        readingStyle(element, "display", "none"); refreshNeeded = true; continue;
      }
      const view = viewport.getBoundingClientRect(), col = column.getBoundingClientRect();
      const isCard = config.readingMode === "cards";
      const isFocus = config.readingMode === "focus";
      const viewBounds = {left: Math.max(0, view.left), right: Math.min(windowWidth, view.right), top: Math.max(0, view.top), bottom: Math.min(windowHeight, view.bottom)};
      const visible = isCard ? readingClipBounds(target.parentElement, viewport, viewBounds, clipBoundsCache) : viewBounds;
      const box = isCard ? target.getBoundingClientRect() : col;
      const spacing = cardSpacing.get(target) || {top: 0, bottom: 0};
      const bounds = isCard ? {left: Math.max(col.left, box.left - 10), right: Math.min(col.right, box.right + 10), top: box.top - spacing.top, bottom: box.bottom + spacing.bottom} :
        {left: Math.max(col.left - (isFocus ? 48 : 0), visible.left), right: Math.min(col.right + (isFocus ? 48 : 0), visible.right), top: visible.top, bottom: visible.bottom};
      const cutTop = Math.max(0, visible.top - bounds.top), cutRight = Math.max(0, bounds.right - visible.right);
      const cutBottom = Math.max(0, bounds.bottom - visible.bottom), cutLeft = Math.max(0, visible.left - bounds.left);
      const width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
      if (box.width <= 0 || (isCard && box.height <= 0) || height <= 0 || width <= 0 || visible.right <= visible.left || visible.bottom <= visible.top || bounds.right <= visible.left || bounds.left >= visible.right || bounds.bottom <= visible.top || bounds.top >= visible.bottom) {
        if (box.width <= 0 || col.width <= 0 || view.width <= 0 || view.height <= 0) refreshNeeded = true;
        readingStyle(element, "display", "none"); continue;
      }
      const radius = config.readingMode === "focus" ? 0 : isCard ? 16 : 18;
      const columnStyle = isFocus ? getComputedStyle(column) : null;
      // Spend the available gutter and native column padding on the fade, so
      // the first and last text characters still sit on the full-strength tint.
      const leftFeather = isFocus ? Math.min(72, Math.max(0, col.left - bounds.left + (parseFloat(columnStyle.paddingLeft) || 0))) : 0;
      const rightFeather = isFocus ? Math.min(72, Math.max(0, bounds.right - col.right + (parseFloat(columnStyle.paddingRight) || 0))) : 0;
      const mask = isFocus ? `linear-gradient(to right,transparent,black ${leftFeather}px,black calc(100% - ${rightFeather}px),transparent)` : "none";
      readingStyle(element, "display", "block");
      readingStyle(element, "left", bounds.left + "px");
      readingStyle(element, "top", bounds.top + "px");
      readingStyle(element, "width", width + "px");
      readingStyle(element, "height", height + "px");
      readingStyle(element, "border-radius", radius + "px");
      readingStyle(element, "clip-path", `inset(${cutTop}px ${cutRight}px ${cutBottom}px ${cutLeft}px round ${radius}px)`);
      readingStyle(element, "background-color", `rgba(${panel},${config.readingOpacity})`);
      readingStyle(element, "backdrop-filter", config.readingBlur > 0 ? `blur(${config.readingBlur}px)` : "none");
      readingStyle(element, "-webkit-backdrop-filter", config.readingBlur > 0 ? `blur(${config.readingBlur}px)` : "none");
      readingStyle(element, "mask-image", mask);
      readingStyle(element, "-webkit-mask-image", mask);
      readingStyle(element, "box-shadow", config.readingMode === "focus" ? "none" : `inset 0 0 0 1px rgba(${edge},${config.readingOpacity * 0.14})`);
      if (!element.isConnected) layer.append(element);
    }
    if (refreshNeeded) scheduleSync();
  }

  function syncSurfaces() {
    if (!active || !document.body) return;
    observeSettingsVisibility();
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
    syncReadingSurfaces();
  }

  function scheduleSync() {
    if (!active || frame) return;
    frame = requestAnimationFrame(() => { frame = 0; syncSurfaces(); });
  }

  // ChatGPT's CSS modules use either _Name_hash or Name-hash. In the latter
  // format require a class-token boundary so related names (for example
  // FullHeightPageSurface) do not match the decorative component itself.
  function nativeModuleClass(name) {
    return `:is([class*="_${name}_"],[class^="${name}-"],[class*=" ${name}-"])`;
  }

  function updateOwnedStyles() {
    if (!config || !layer || !stylesheet) return;
    const root = `html[${ROOT_ATTRIBUTE}="${owner}"]:not([${MUTED_ATTRIBUTE}="${owner}"])`;
    const outsideProtected = `:not(:is(dialog,dialog *,[role=dialog],[role=dialog] *,[role=alertdialog],[role=alertdialog] *,[role=menu],[role=menu] *,[role=listbox],[role=listbox] *,pre,pre *,code,code *,[data-testid=settings-modal],[data-testid=settings-modal] *,[data-settings-page],[data-settings-page] *,${settingsPageContent},${settingsPageContent} *))`;
    const outsideDotsReading = ":not(:is(.messaging-attachments,.messaging-attachments *,.messaging-root:not(.messaging-embedded),.messaging-root:not(.messaging-embedded) *,.reply-chain-panel,.reply-chain-panel *,.reply-chain-transcript,.reply-chain-transcript *,.message-list .message-list,.message-list .message-list *,[data-orbit-message-block],[data-orbit-message-block] *,[data-option-picker-choice],[data-option-picker-choice] *,[data-transcript-role=user],[data-transcript-role=user] *,button,button *))";
    const dotsReadingRow = `${root} .message-list:is([${READING_ATTRIBUTE}="${owner}:sheet"],[${READING_ATTRIBUTE}="${owner}:cards"],[${READING_ATTRIBUTE}="${owner}:focus"]) > .message-row.assistant`;
    const dotsTextBacking = `${dotsReadingRow} .message-surface > .message-bubble:is([data-markdown-text-style="assistant-message"],:has([data-markdown-text-style="assistant-message"]))${outsideProtected}${outsideDotsReading}`;
    const dotsTextPart = `${dotsReadingRow} .message-bubble[data-orbit-message-text-part][data-markdown-text-style="assistant-message"]${outsideProtected}${outsideDotsReading}`;
    const dotsMaterial = `${dotsReadingRow} [data-avatar-overlay-material-variant="transcript-message"]:is([data-transcript-role="assistant"],:has(> [data-orbit-message-text-part])):has([data-markdown-text-style="assistant-message"])${outsideProtected}${outsideDotsReading}`;
    const dotsFooter = `.messaging-root.messaging-embedded[${SURFACE_ATTRIBUTE}="${owner}"] .conversation-footer`;
    const composer = `${nativeModuleClass("ComposerLayoutRoot")}:is([data-composer-surface-variant="default"],[data-composer-surface-variant="opaque"],[data-composer-surface-variant="secondary"])`;
    const environmentPanel = '[data-in-progress-fixed-content][class~="group/environment-actions"] .bg-surface-elevated-secondary';
    const utilityPanel = '[data-composer-utility-rail].bg-background-composer-action-bar';
    const summaryPanel = '[data-summary-panel-variant].bg-surface-elevated-secondary';
    const decorativeBackground = `div[aria-hidden="true"]${nativeModuleClass("background")}:is(${nativeModuleClass("surface")},${nativeModuleClass("fade")},${nativeModuleClass("combined")}):empty`;
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
${root} [data-app-shell-page-sidebar="true"] ${nativeModuleClass("MainContentLeftBorder")}${outsideProtected} {
  border-left-color: transparent !important;
}
/* Dots portals this decorative fade beside its real header controls, outside
   the messaging roots. Keep the portal, anchor geometry and controls intact. */
${root} [data-app-shell-main-content-layout] div[aria-hidden="true"]${nativeModuleClass("floatingHeader")}[style*="--orbit-messaging-header-"]:empty${outsideProtected} {
  background-color: transparent !important;
  background-image: none !important;
}
/* These are empty, aria-hidden native paint layers. Their containing wrappers
   also hold transcript/controls, so never hide those wrappers themselves. */
${root} [data-app-shell-main-content-top-fade] div[aria-hidden="true"]${nativeModuleClass("MainContentTopFade")}:empty${outsideProtected},
${root} .thread-scroll-container ${decorativeBackground}${outsideProtected},
${root} [data-thread-footer-background] ${decorativeBackground}${outsideProtected},
${root} [data-thread-scroll-footer="true"] ${decorativeBackground}${outsideProtected},
${root} ${dotsFooter} ${decorativeBackground}${outsideProtected} {
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
/* Dots has a separate messaging footer. Clear only its page-colored backing;
   retain the composer, bubbles, attachments, and the shared color tokens. */
${root} ${dotsFooter} .composer-disclaimer${outsideProtected},
${root} ${dotsFooter} .typing-indicator:not(:empty)${outsideProtected} {
  background-color: transparent !important;
  background-image: none !important;
}
${root} ${dotsFooter} .composer-wrap:not([data-has-composer-surface])${outsideProtected} {
  border-bottom-color: transparent !important;
}
/* The page card's native shadow is a separate empty overlay beside the sidebar. */
${root} [data-app-shell-frame] div[aria-hidden="true"]${nativeModuleClass("PageSurface")}:empty${outsideProtected} {
  box-shadow: none !important;
}
/* User messages can carry the native Accent fill on this element itself. */
${root} [data-message-author-role="assistant"]${outsideProtected} {
  background-color: rgba(${panel},${config.panelOpacity}) !important;
  border-radius: 14px;
}
/* Work-mode panels paint outside the ordinary composer and sidebar. Match the
   native filled surfaces; floating rails and unstyled summaries stay native. */
${root} ${environmentPanel}${outsideProtected},
${root} ${utilityPanel}${outsideProtected},
${root} ${summaryPanel}${outsideProtected} {
  background-color: rgba(${panel},${config.panelOpacity}) !important;
  background-image: none !important;
  box-shadow: none !important;
}
/* Summary section headings and their top-gap caps repeat the card's fill.
   Let the single outer tint show through without changing sticky behavior or
   the hover/selection backgrounds on the controls inside each section. */
${root} ${summaryPanel} header${outsideProtected},
${root} ${summaryPanel} header${outsideProtected}::before {
  background-color: transparent !important;
  background-image: none !important;
}
/* A reading treatment replaces our assistant-wrapper tint, rather than
   multiplying Panel Opacity into its independently controlled opacity. Native
   user bubbles, code backgrounds and result-card surfaces are left intact. */
${root} [${READING_ATTRIBUTE}="${owner}:sheet"] [data-message-author-role="assistant"]${outsideProtected},
${root} [${READING_ATTRIBUTE}="${owner}:cards"] [data-message-author-role="assistant"]${outsideProtected},
${root} [${READING_ATTRIBUTE}="${owner}:focus"] [data-message-author-role="assistant"]${outsideProtected} {
  background-color: transparent !important;
}
/* Dots uses native text bubbles/material instead of the standard assistant
   wrapper. Replace only that verified text backing while a reading treatment
   is active, so its native tint/glass does not stack with Reading Opacity.
   Rich blocks, option buttons, user bubbles and unrelated rooms stay native. */
${dotsTextBacking},
${dotsTextPart},
${dotsMaterial},
${dotsMaterial}::before {
  background-color: transparent !important;
  background-image: none !important;
  box-shadow: none !important;
  backdrop-filter: none !important;
  -webkit-backdrop-filter: none !important;
}
${dotsMaterial} {
  -owl-native-material: none !important;
}
/* Native normal composers paint their root, except on Home where only their
   body paints. Use the local surface token, leaving shared action-color tokens
   native so send/stop buttons and focus outlines keep following Accent. */
${root} ${composer}${outsideProtected} {
  --composer-layout-surface-background: rgba(${panel},${config.panelOpacity}) !important;
  --composer-layout-surface-shadow: none !important;
  --composer-layout-surface-backdrop-filter: none !important;
}
${root} ${composer}:not([data-composer-utility-bar-variant="home"])${outsideProtected},
${root} ${composer}[data-composer-utility-bar-variant="home"] ${nativeModuleClass("ComposerLayoutBody")}${outsideProtected} {
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
      readingMode: active && config ? config.readingMode : "none",
      readingSurfaceCount: [...readingPlates.values()].filter(record => record.element.style.display !== "none").length,
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
    settingsVisibilityObserver?.disconnect();
    treeObserver = themeObserver = settingsVisibilityObserver = null;
    settingsObservedNodes.clear();
    settingsCandidates.clear();
    clearReading();
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
