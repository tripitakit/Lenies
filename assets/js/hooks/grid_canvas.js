// GridCanvas hook: renders the world's 4 layers (lenies, resource,
// carcass, carcass_hue) on the dashboard's full-height canvas, with:
//
//   - data-show-{lenies,resource,carcass} : per-layer visibility toggles
//   - data-highlight-hue                  : when > 0, dim every cell whose
//                                           species byte ≠ highlight-hue
//   - mouse wheel                         : zoom in/out at the cursor
//   - mousedown + drag                    : pan the view in buffer space
//   - click (no drag)                     : recenter the view on the clicked
//                                           cell (deferred so dblclick
//                                           can cancel it cleanly)
//   - double-click                        : if a Lenie occupies the cell,
//                                           push `select_lenie_at_cell`
//                                           (server navigates to editor)
//
// Wire format (per Lenies.SpeciesColor / LeniesWeb.GridRenderer):
//   - lenies      : 1 byte/cell. 0 = empty, 1..255 = species hue byte
//   - resource    : 1 byte/cell, 0..100 (clamped)
//   - carcass     : 1 byte/cell, 0..50 (clamped intensity)
//   - carcass_hue : 1 byte/cell. 0 = no species color, 1..255 = species hue byte
//
// Hue byte → degrees: deg = (byte - 1) / 255 * 360. Must match
// Lenies.SpeciesColor.byte_to_hex/1 (S=0.70, L=0.55).
//
// Pixel composition priority per cell:
//   1. occupied (lenies > 0)  + show_lenies   → HSL species fill, alpha 255
//                                               (carcass under it blends in
//                                               at 30% — see below)
//   2. carcass > 0           + show_carcass   → species (or red) lerped
//                                               toward light gray as it
//                                               decays, alpha 255
//   3. resource > 0          + show_resource  → green channel = resource * 2
//   4. default                                → empty (alpha 192)
//
// Carcass decay holds alpha constant and lerps colour toward CARCASS_GRAY
// so old carcasses stay legible on the black background.

import { HUE_LUT } from "./grid_canvas_hue_lut.js";

const CARCASS_MAX = 50;
const CARCASS_GRAY = 180;

const MIN_ZOOM = 1;
const MAX_ZOOM = 32;
const ZOOM_STEP = 1.2;
const CLICK_DRAG_THRESHOLD_PX = 3;
// Window in which a second click can promote to a dblclick. Must exceed
// most browsers' dblclick threshold (≈500 ms on macOS / Windows) so a
// slow dblclick doesn't trigger the recenter timer between the two
// clicks and shift the view out from under the dblclick's cell math.
const CLICK_RECENTER_DELAY_MS = 500;
// Re-pull tooltip info from the server every N ms while the cursor
// sits on the same cell. Recovery path for stale cached-occupancy: a
// Lenie may have left the cell between render_frame ticks, in which
// case the server's authoritative reply (`present: false`) flips the
// tooltip + cursor back to empty within one tick of this interval.
const HOVER_REFRESH_INTERVAL_MS = 80;

const GridCanvas = {
  mounted() {
    this.canvas = this.el;
    this.ctx = this.canvas.getContext("2d");
    this.gridW = parseInt(this.canvas.dataset.gridWidth, 10);
    this.gridH = parseInt(this.canvas.dataset.gridHeight, 10);

    this.bufferCanvas = document.createElement("canvas");
    this.bufferCanvas.width = this.gridW;
    this.bufferCanvas.height = this.gridH;
    this.bufferCtx = this.bufferCanvas.getContext("2d");

    this.lastPayload = null;

    // View state — viewport in buffer coordinates.
    this.zoom = 1;
    this.centerX = this.gridW / 2;
    this.centerY = this.gridH / 2;

    this.isDragging = false;
    this.dragMoved = false;
    this.dragStart = null;
    // Pending single-click recenter — held in a timer so a follow-up
    // dblclick can cancel it before it shifts the view out from under
    // the dblclick handler's cursor-to-cell math.
    this.pendingClickTimer = null;

    // Cache of the decoded lenies layer for cursor-hover lookups, so
    // mousemove doesn't pay the base64 decode cost every event.
    this.cachedLenieBytes = null;

    // Hover-tooltip state — see updateHoverCursor / onTooltipInfo.
    this.hoveredCell = null;            // {x, y} | null
    this.lastCursorClient = null;       // {clientX, clientY}
    this.tooltipEl = this.createTooltipEl();
    // Time-based throttle for hover-info round-trips. Cached-occupancy
    // (the JS `cachedLenieBytes` snapshot) lags reality by ~100-500ms
    // because it updates only on render_frame; the server's view is
    // always fresh. So we re-ask the server every ~80ms while the
    // cursor sits on what JS thinks is an occupied cell — that way a
    // Lenie moving off the cell flips the tooltip + cursor back to
    // empty within one throttle window, instead of leaving the tooltip
    // permanently stuck-hidden because we never re-pushed.
    this.lastHoverRequestAt = 0;

    this.handleEvent("render_frame", (payload) => {
      this.lastPayload = payload;
      this.cachedLenieBytes = this.decodeBase64(payload.lenies);
      this.renderFrame();
    });

    // Server pushes hover info in response to our request_lenie_hover
    // event. Discard stale responses — the cursor may have moved to a
    // different cell while the round-trip was in flight.
    this.handleEvent("lenie_hover_info", (info) => this.onTooltipInfo(info));

    this.attachInteractionHandlers();

    // Initial black fill until the first frame arrives.
    this.ctx.fillStyle = "#000";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
  },

  // LiveView morphs data-highlight-hue and the data-show-* attributes
  // when the user toggles a layer or selects a species. Re-render with
  // the cached payload so the change takes effect immediately without
  // waiting for the next server frame.
  updated() {
    if (this.lastPayload) this.renderFrame();
  },

  attachInteractionHandlers() {
    // Wheel = zoom toward the cursor (cursor stays anchored on the same
    // buffer cell across the zoom).
    this.onWheel = (e) => {
      e.preventDefault();
      const { mx, my, bufX, bufY } = this.cursorToBuffer(e);
      const factor = e.deltaY < 0 ? ZOOM_STEP : 1 / ZOOM_STEP;
      const newZoom = clamp(this.zoom * factor, MIN_ZOOM, MAX_ZOOM);
      if (newZoom === this.zoom) return;
      this.zoom = newZoom;
      const eff = this.effectiveScale();
      this.centerX = bufX - (mx - this.canvas.width / 2) / eff;
      this.centerY = bufY - (my - this.canvas.height / 2) / eff;
      this.clampCenter();
      this.requestDraw();
    };

    this.onMouseDown = (e) => {
      if (e.button !== 0) return;
      this.isDragging = true;
      this.dragMoved = false;
      this.dragStart = {
        clientX: e.clientX,
        clientY: e.clientY,
        centerX: this.centerX,
        centerY: this.centerY,
      };
      this.canvas.style.cursor = "grabbing";
    };

    this.onMouseMove = (e) => {
      if (this.isDragging) {
        const dx = e.clientX - this.dragStart.clientX;
        const dy = e.clientY - this.dragStart.clientY;
        if (Math.abs(dx) + Math.abs(dy) > CLICK_DRAG_THRESHOLD_PX) {
          this.dragMoved = true;
        }
        // Convert pixel delta to buffer-coord delta. Drag right ⇒ view
        // shifts left in buffer space (we look further left).
        const rect = this.canvas.getBoundingClientRect();
        const eff = this.effectiveScale() * (this.canvas.width / rect.width);
        this.centerX = this.dragStart.centerX - dx / eff;
        this.centerY = this.dragStart.centerY - dy / eff;
        this.clampCenter();
        this.requestDraw();
        return;
      }
      // Idle hover: flip the cursor to `pointer` when over an
      // occupied (Lenie) cell so the user has a visual hint that
      // dblclick will open the codeome editor.
      this.updateHoverCursor(e);
    };

    this.onMouseUp = (e) => {
      if (!this.isDragging) return;
      const wasClick = !this.dragMoved;
      this.isDragging = false;
      this.canvas.style.cursor = "grab";
      if (!wasClick) return;
      // Second click of a click pair: trigger the edit-Lenie navigation
      // directly from mouseup. We don't wait for the browser's dblclick
      // event because its position-tolerance threshold can drop it on
      // small movement between the two clicks. e.detail counts
      // consecutive clicks at roughly the same spot inside the OS
      // dblclick window.
      if (e.detail >= 2) {
        if (this.pendingClickTimer) {
          clearTimeout(this.pendingClickTimer);
          this.pendingClickTimer = null;
        }
        this.fireEditAtCursor(e);
        return;
      }
      // Defer the recenter: if a dblclick (or second mouseup) follows,
      // it cancels the timer before centerX/Y change, so the second
      // click still resolves to the originally-clicked cell.
      const { bufX, bufY } = this.cursorToBuffer(e);
      if (this.pendingClickTimer) clearTimeout(this.pendingClickTimer);
      this.pendingClickTimer = setTimeout(() => {
        this.pendingClickTimer = null;
        this.centerX = bufX;
        this.centerY = bufY;
        this.clampCenter();
        this.requestDraw();
      }, CLICK_RECENTER_DELAY_MS);
    };

    this.onMouseLeave = () => {
      this.isDragging = false;
      this.canvas.style.cursor = "grab";
      // Cursor left the canvas entirely — drop hover state so a
      // re-entry on the same cell triggers a fresh tooltip request.
      this.setHoveredCell(null);
    };

    this.onDoubleClick = (e) => {
      // The dblclick event is now a secondary trigger; the primary path
      // is onMouseUp's e.detail >= 2 branch. We still preventDefault
      // here so browsers don't fall back to a select-word gesture.
      e.preventDefault();
      if (this.pendingClickTimer) {
        clearTimeout(this.pendingClickTimer);
        this.pendingClickTimer = null;
      }
      this.fireEditAtCursor(e);
    };

    this.canvas.style.cursor = "grab";
    this.canvas.addEventListener("wheel", this.onWheel, { passive: false });
    this.canvas.addEventListener("mousedown", this.onMouseDown);
    this.canvas.addEventListener("mousemove", this.onMouseMove);
    this.canvas.addEventListener("mouseup", this.onMouseUp);
    this.canvas.addEventListener("mouseleave", this.onMouseLeave);
    this.canvas.addEventListener("dblclick", this.onDoubleClick);
  },

  detachInteractionHandlers() {
    if (!this.onWheel) return;
    this.canvas.removeEventListener("wheel", this.onWheel);
    this.canvas.removeEventListener("mousedown", this.onMouseDown);
    this.canvas.removeEventListener("mousemove", this.onMouseMove);
    this.canvas.removeEventListener("mouseup", this.onMouseUp);
    this.canvas.removeEventListener("mouseleave", this.onMouseLeave);
    this.canvas.removeEventListener("dblclick", this.onDoubleClick);
  },

  // Resolve the cell under `e` to a buffer coordinate and ask the
  // server to open its codeome editor. Empty cells / out-of-bounds are
  // a no-op (the server's lookup_lenie_at_cell returns :error and the
  // dashboard handler short-circuits without navigating). Idempotent
  // if called twice on the same dblclick (server-side navigate is the
  // same target both times).
  fireEditAtCursor(e) {
    const { bufX, bufY } = this.cursorToBuffer(e);
    const x = Math.floor(bufX);
    const y = Math.floor(bufY);
    if (x < 0 || y < 0 || x >= this.gridW || y >= this.gridH) return;
    this.pushEvent("select_lenie_at_cell", { x, y });
  },

  // Hover-cursor + tooltip dispatcher. Runs on every idle mousemove.
  //   - Cursor → `pointer` over an occupied cell, `grab` otherwise.
  //   - Tooltip → push `request_lenie_hover` to the server on cell
  //     entry AND periodically while the cursor sits on the same cell
  //     (every ~80ms). The periodic re-push is the recovery path for
  //     stale cached-occupancy: when a Lenie moves off the cell the JS
  //     still thinks it's occupied, but the server's reply will say
  //     `present: false` and we'll hide the tooltip + correct the
  //     cached byte so the cursor flips back too.
  updateHoverCursor(e) {
    if (!this.cachedLenieBytes) return;
    this.lastCursorClient = { clientX: e.clientX, clientY: e.clientY };

    const { bufX, bufY } = this.cursorToBuffer(e);
    const x = Math.floor(bufX);
    const y = Math.floor(bufY);

    if (x < 0 || y < 0 || x >= this.gridW || y >= this.gridH) {
      this.canvas.style.cursor = "grab";
      this.setHoveredCell(null);
      return;
    }

    const occupied = this.cachedLenieBytes[y * this.gridW + x] > 0;
    this.canvas.style.cursor = occupied ? "pointer" : "grab";

    if (!occupied) {
      this.setHoveredCell(null);
      return;
    }

    const cellChanged =
      !this.hoveredCell ||
      this.hoveredCell.x !== x ||
      this.hoveredCell.y !== y;

    if (cellChanged) {
      this.setHoveredCell({ x, y });
      this.requestLenieHover(x, y, true);
    } else {
      // Same cell as last mousemove: reposition the visible tooltip
      // AND re-ask the server periodically so a Lenie that just left
      // (cached-occupancy lag) is detected.
      this.positionTooltip();
      this.requestLenieHover(x, y, false);
    }
  },

  // Time-throttled tooltip request. `force=true` (new cell) always
  // pushes; `force=false` (same-cell repeat) pushes only if the last
  // request was more than HOVER_REFRESH_INTERVAL_MS ago.
  requestLenieHover(x, y, force) {
    const now = Date.now();
    if (!force && now - this.lastHoverRequestAt < HOVER_REFRESH_INTERVAL_MS) {
      return;
    }
    this.lastHoverRequestAt = now;
    this.pushEvent("request_lenie_hover", { x, y });
  },

  // Transition helper: when leaving a Lenie cell (or the canvas), hide
  // the tooltip and forget the cell so the next entry triggers a fresh
  // request even if it's the same coord we left from.
  setHoveredCell(cell) {
    this.hoveredCell = cell;
    if (!cell) this.hideTooltip();
  },

  onTooltipInfo(info) {
    if (!info) return;

    // If the server's authoritative view says the cell is empty,
    // correct the JS-side cached occupancy so the cursor flips back
    // to `grab` on the next mousemove — otherwise the stale cached
    // bytes would keep the cursor as `pointer` over a now-empty cell
    // until the next render_frame refresh (~100-500ms later) and the
    // tooltip would never re-appear because subsequent requests keep
    // returning `present: false`.
    if (!info.present) {
      if (this.cachedLenieBytes) {
        const idx = info.y * this.gridW + info.x;
        if (idx >= 0 && idx < this.cachedLenieBytes.length) {
          this.cachedLenieBytes[idx] = 0;
        }
      }
      // If the user was hovering this cell, hide the tooltip and
      // forget the cell so the next mousemove re-evaluates from a
      // clean state (cursor will also pick up the corrected byte).
      if (
        this.hoveredCell &&
        this.hoveredCell.x === info.x &&
        this.hoveredCell.y === info.y
      ) {
        this.setHoveredCell(null);
      }
      return;
    }

    // `present: true` — show the tooltip if the user is still hovering
    // this cell. Stale responses (cursor moved on before the round-trip
    // completed) are dropped silently.
    if (
      !this.hoveredCell ||
      this.hoveredCell.x !== info.x ||
      this.hoveredCell.y !== info.y
    ) {
      return;
    }
    // Defensive: if the tooltipEl was somehow removed (e.g., the hook
    // was destroyed then revived without going through `mounted`),
    // recreate it on demand so the tooltip can never be permanently
    // hidden by a stale null reference.
    if (!this.tooltipEl) this.tooltipEl = this.createTooltipEl();
    this.tooltipEl.innerHTML = this.renderTooltip(info);
    this.tooltipEl.style.display = "block";
    this.positionTooltip();
  },

  hideTooltip() {
    if (this.tooltipEl) this.tooltipEl.style.display = "none";
  },

  positionTooltip() {
    if (!this.tooltipEl || !this.lastCursorClient) return;
    if (this.tooltipEl.style.display === "none") return;
    // 14px right + 14px below the cursor keeps the tooltip clear of
    // the cursor's hit-area without flickering when it lands on the
    // edge of the cell.
    const x = this.lastCursorClient.clientX + 14;
    const y = this.lastCursorClient.clientY + 14;
    this.tooltipEl.style.left = `${x}px`;
    this.tooltipEl.style.top = `${y}px`;
  },

  // Render the tooltip's body. `seed_origin` may be null (Lenies spawned
  // before seed_origin tracking, or by direct Lenie.start_link without
  // a seed_origin opt) — show "—" in that case.
  renderTooltip(info) {
    const seed = info.seed_origin ? this.escapeHtml(info.seed_origin) : "—";
    return (
      `<div class="lenie-tooltip-row"><span class="lenie-tooltip-label">origin</span><span>${seed}</span></div>` +
      `<div class="lenie-tooltip-row"><span class="lenie-tooltip-label">age</span><span>${info.age}</span></div>` +
      `<div class="lenie-tooltip-row"><span class="lenie-tooltip-label">energy</span><span>${info.energy}</span></div>`
    );
  },

  escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  },

  createTooltipEl() {
    const el = document.createElement("div");
    el.className = "lenie-tooltip";
    el.style.display = "none";
    document.body.appendChild(el);
    return el;
  },

  // Display pixels per buffer cell at current zoom.
  effectiveScale() {
    return (this.canvas.width / this.gridW) * this.zoom;
  },

  // Convert a mouse event's client coords into both canvas-internal
  // pixel coords and the buffer cell under the cursor.
  cursorToBuffer(e) {
    const rect = this.canvas.getBoundingClientRect();
    const mx = (e.clientX - rect.left) * (this.canvas.width / rect.width);
    const my = (e.clientY - rect.top) * (this.canvas.height / rect.height);
    const eff = this.effectiveScale();
    const bufX = this.centerX + (mx - this.canvas.width / 2) / eff;
    const bufY = this.centerY + (my - this.canvas.height / 2) / eff;
    return { mx, my, bufX, bufY };
  },

  // Keep the visible buffer region within the grid bounds so panning
  // never reveals empty space outside the world.
  clampCenter() {
    const eff = this.effectiveScale();
    const halfW = this.canvas.width / 2 / eff;
    const halfH = this.canvas.height / 2 / eff;
    if (halfW * 2 >= this.gridW) {
      this.centerX = this.gridW / 2;
    } else {
      this.centerX = clamp(this.centerX, halfW, this.gridW - halfW);
    }
    if (halfH * 2 >= this.gridH) {
      this.centerY = this.gridH / 2;
    } else {
      this.centerY = clamp(this.centerY, halfH, this.gridH - halfH);
    }
  },

  // Coalesce interaction-driven redraws to the next animation frame —
  // wheel/mousemove can fire faster than 60 Hz.
  requestDraw() {
    if (!this.lastPayload) return;
    if (this.drawScheduled) return;
    this.drawScheduled = true;
    requestAnimationFrame(() => {
      this.drawScheduled = false;
      this.renderFrame();
    });
  },

  decodeBase64(b64) {
    const binStr = atob(b64);
    const len = binStr.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) bytes[i] = binStr.charCodeAt(i);
    return bytes;
  },

  renderFrame() {
    const { lenies, resource, carcass, carcass_hue, width, height } = this.lastPayload;
    const lBytes = this.decodeBase64(lenies);
    const rBytes = this.decodeBase64(resource);
    const cBytes = this.decodeBase64(carcass);
    const hBytes = this.decodeBase64(carcass_hue);

    const showLenies = this.canvas.hasAttribute("data-show-lenies");
    const showResource = this.canvas.hasAttribute("data-show-resource");
    const showCarcass = this.canvas.hasAttribute("data-show-carcass");
    const highlightHue = parseInt(this.canvas.dataset.highlightHue || "0", 10);

    const imageData = this.bufferCtx.createImageData(width, height);
    const px = imageData.data; // RGBA

    for (let i = 0; i < width * height; i++) {
      const speciesByte = lBytes[i];
      const res = rBytes[i];
      const carc = cBytes[i];
      const carcHueByte = hBytes[i];

      let r = 0, g = 0, b = 0, a = 192;

      // Precompute the carcass display colour once: species (or red for
      // untagged) lerped toward light gray by t = 1 - carc/CARCASS_MAX.
      // Used both as the standalone carcass fill and as the 30% tint
      // when a Lenie sits on top of an old carcass.
      let carcRgb = null;
      if (showCarcass && carc > 0) {
        const fresh = carcHueByte > 0
          ? HUE_LUT[carcHueByte]
          : { r: 255, g: 60, b: 60 };
        const t = 1 - carc / CARCASS_MAX;
        carcRgb = {
          r: Math.round(fresh.r + (CARCASS_GRAY - fresh.r) * t),
          g: Math.round(fresh.g + (CARCASS_GRAY - fresh.g) * t),
          b: Math.round(fresh.b + (CARCASS_GRAY - fresh.b) * t),
        };
      }

      if (showLenies && speciesByte > 0) {
        const rgb = HUE_LUT[speciesByte];
        r = rgb.r; g = rgb.g; b = rgb.b;
        a = 255;
        // A carcass sitting under a Lenie (low/zero carcass_decay,
        // respawn over remains) blends in at 30% so the carcass checkbox
        // stays meaningful even when species are on top.
        if (carcRgb) {
          r = Math.floor(r * 0.7 + carcRgb.r * 0.3);
          g = Math.floor(g * 0.7 + carcRgb.g * 0.3);
          b = Math.floor(b * 0.7 + carcRgb.b * 0.3);
        }
      } else if (carcRgb) {
        r = carcRgb.r; g = carcRgb.g; b = carcRgb.b;
        a = 255;
      } else if (showResource && res > 0) {
        g = Math.min(255, res * 2);
      }

      // Dim everything that doesn't belong to the highlighted species.
      // highlightHue === 0 means "no highlight" — full intensity for all.
      if (highlightHue > 0 && speciesByte !== highlightHue) {
        a = Math.floor(a * 0.3);
      }

      const off = i * 4;
      px[off] = r;
      px[off + 1] = g;
      px[off + 2] = b;
      px[off + 3] = a;
    }

    this.bufferCtx.putImageData(imageData, 0, 0);

    // Nearest-neighbor upscale of the current viewport onto the display
    // canvas. zoom=1 + center at grid center => full grid fills canvas
    // (matches the pre-pan/zoom behavior).
    const eff = this.effectiveScale();
    const srcW = this.canvas.width / eff;
    const srcH = this.canvas.height / eff;
    const sx = this.centerX - srcW / 2;
    const sy = this.centerY - srcH / 2;

    this.ctx.imageSmoothingEnabled = false;
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.ctx.drawImage(
      this.bufferCanvas,
      sx, sy, srcW, srcH,
      0, 0, this.canvas.width, this.canvas.height
    );
  },

  destroyed() {
    this.detachInteractionHandlers();
    if (this.pendingClickTimer) {
      clearTimeout(this.pendingClickTimer);
      this.pendingClickTimer = null;
    }
    if (this.tooltipEl && this.tooltipEl.parentNode) {
      this.tooltipEl.parentNode.removeChild(this.tooltipEl);
    }
    this.tooltipEl = null;
    this.hoveredCell = null;
    this.lastCursorClient = null;
    this.lastPayload = null;
    this.cachedLenieBytes = null;
  },
};

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

export default GridCanvas;
