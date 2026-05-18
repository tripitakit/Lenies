// WorldDetailCanvas hook: renders the same render_frame payload as the
// dashboard's GridCanvas hook but at a larger pixel scale, with an
// optional "highlight" filter that dims every pixel whose species byte
// does not match data-highlight-hue, and with pan/zoom controls:
//
//   - mouse wheel       : zoom in/out at the cursor (cursor stays anchored)
//   - mousedown + drag  : pan the view in buffer space
//   - click (no drag)   : center the view on the clicked buffer cell
//   - double-click      : if the cell holds a Lenie, navigate to its
//                         codeome editor (no-op on empty cells)
//
// The highlight byte is read at draw time from the DOM attribute, so
// LiveView re-renders that change data-highlight-hue automatically take
// effect on the next frame without any extra event plumbing.

import { HUE_LUT } from "./grid_canvas_hue_lut.js";

const MIN_ZOOM = 1;
const MAX_ZOOM = 32;
const ZOOM_STEP = 1.2;
const CLICK_DRAG_THRESHOLD_PX = 3;
// Window in which a second click can promote to a dblclick. Must exceed
// most browsers' dblclick threshold so we don't recenter and shift the
// view out from under the dblclick handler's cursor→cell math.
const CLICK_RECENTER_DELAY_MS = 250;
// Carcasses keep constant alpha but lerp toward a light gray as they
// decay (carc 50→0) so they stay visible against the black background.
// Mirrors the dashboard's GridCanvas hook.
const CARCASS_MAX = 50;
const CARCASS_GRAY = 180;

const WorldDetailCanvas = {
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

    this.handleEvent("render_frame", (payload) => {
      this.lastPayload = payload;
      this.renderFrame();
    });

    this.attachInteractionHandlers();

    // Initial black fill until the first frame arrives.
    this.ctx.fillStyle = "#000";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
  },

  // LiveView morphs data-highlight-hue when the user clicks a row.
  // Re-render with the cached payload so the dim filter applies
  // immediately without waiting for the next server frame.
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
      if (!this.isDragging) return;
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
    };

    this.onMouseUp = (e) => {
      if (!this.isDragging) return;
      const wasClick = !this.dragMoved;
      this.isDragging = false;
      this.canvas.style.cursor = "grab";
      if (!wasClick) return;
      // Skip recenter on the second mouseup of a double-click — the
      // dblclick handler will clear the pending recenter from the first
      // mouseup and navigate instead. e.detail counts consecutive clicks
      // at roughly the same spot within the OS dblclick window.
      if (e.detail >= 2) return;
      // Defer the recenter: if a dblclick follows, it cancels the timer
      // before centerX/Y change, so cursorToBuffer in onDoubleClick still
      // points at the originally-clicked cell.
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
    };

    this.onDoubleClick = (e) => {
      e.preventDefault();
      // Cancel the deferred recenter from the first mouseup before
      // reading the cursor cell — otherwise the recenter could already
      // have run if the user clicked slowly, but more importantly we
      // never want it to run after the dblclick decides to navigate.
      if (this.pendingClickTimer) {
        clearTimeout(this.pendingClickTimer);
        this.pendingClickTimer = null;
      }
      const { bufX, bufY } = this.cursorToBuffer(e);
      const x = Math.floor(bufX);
      const y = Math.floor(bufY);
      if (x < 0 || y < 0 || x >= this.gridW || y >= this.gridH) return;
      // Server navigates to the editor if a Lenie occupies the cell,
      // otherwise it's a no-op (empty cell).
      this.pushEvent("select_lenie_at_cell", { x, y });
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

    const highlightHue = parseInt(this.canvas.dataset.highlightHue || "0", 10);

    const imageData = this.bufferCtx.createImageData(width, height);
    const px = imageData.data;

    for (let i = 0; i < width * height; i++) {
      const speciesByte = lBytes[i];
      const res = rBytes[i];
      const carc = cBytes[i];
      const carcHueByte = hBytes[i];

      let r = 0, g = 0, b = 0, a = 192;

      if (speciesByte > 0) {
        const rgb = HUE_LUT[speciesByte];
        r = rgb.r; g = rgb.g; b = rgb.b;
        a = 255;
      } else if (carc > 0) {
        const fresh = carcHueByte > 0
          ? HUE_LUT[carcHueByte]
          : { r: 255, g: 60, b: 60 };
        const t = 1 - carc / CARCASS_MAX;
        r = Math.round(fresh.r + (CARCASS_GRAY - fresh.r) * t);
        g = Math.round(fresh.g + (CARCASS_GRAY - fresh.g) * t);
        b = Math.round(fresh.b + (CARCASS_GRAY - fresh.b) * t);
        a = 255;
      } else if (res > 0) {
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
    this.lastPayload = null;
  }
};

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

export default WorldDetailCanvas;
