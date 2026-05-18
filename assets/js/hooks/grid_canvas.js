// GridCanvas hook: renders 4 layers (lenies, resource, carcass, carcass_hue)
// onto the dashboard's 2D canvas.
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
//                                               at 30% with its own decay
//                                               tint — see below)
//   2. carcass > 0           + show_carcass   → species (or red) lerped
//                                               toward light gray as the
//                                               carcass decays, alpha 255
//   3. resource > 0          + show_resource  → green channel = resource * 2
//   4. default                                → empty (alpha 192)
//
// Carcass decay: alpha stays constant so old carcasses don't fade into the
// black background; instead the colour lerps from species (or red) toward
// CARCASS_GRAY as `carc` falls 50→0. Keeps them legible while still
// signalling age.

import { HUE_LUT } from "./grid_canvas_hue_lut.js";

const CARCASS_MAX = 50;
const CARCASS_GRAY = 180;

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

    this.handleEvent("render_frame", (payload) => {
      this.renderFrame(payload);
    });

    this.ctx.fillStyle = "#000";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

    this.canvas.addEventListener("click", (event) => {
      const rect = this.canvas.getBoundingClientRect();
      const x = event.clientX - rect.left;
      const y = event.clientY - rect.top;
      const cellX = Math.floor((x / this.canvas.width) * this.gridW);
      const cellY = Math.floor((y / this.canvas.height) * this.gridH);
      this.pushEvent("cell_clicked", { x: cellX, y: cellY });
    });
  },

  updated() {},

  decodeBase64(b64) {
    const binStr = atob(b64);
    const len = binStr.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) bytes[i] = binStr.charCodeAt(i);
    return bytes;
  },

  renderFrame({ lenies, resource, carcass, carcass_hue, width, height }) {
    const lBytes = this.decodeBase64(lenies);
    const rBytes = this.decodeBase64(resource);
    const cBytes = this.decodeBase64(carcass);
    const hBytes = this.decodeBase64(carcass_hue);

    const showLenies = this.canvas.hasAttribute("data-show-lenies");
    const showResource = this.canvas.hasAttribute("data-show-resource");
    const showCarcass = this.canvas.hasAttribute("data-show-carcass");

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

      const off = i * 4;
      px[off] = r;
      px[off + 1] = g;
      px[off + 2] = b;
      px[off + 3] = a;
    }

    this.bufferCtx.putImageData(imageData, 0, 0);

    this.ctx.imageSmoothingEnabled = false;
    this.ctx.fillStyle = "#000";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    this.ctx.drawImage(
      this.bufferCanvas,
      0,
      0,
      this.canvas.width,
      this.canvas.height
    );
  },
};

export default GridCanvas;
