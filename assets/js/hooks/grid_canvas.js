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
//   2. carcass > 0           + show_carcass   →
//        if carcass_hue > 0 → HSL species fill, alpha = carcass * 4
//        else                → red (255, 60, 60), alpha = carcass * 4
//   3. resource > 0          + show_resource  → green channel = resource * 2
//   4. default                                → empty (alpha 192)

import { HUE_LUT } from "./grid_canvas_hue_lut.js";

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

      if (showLenies && speciesByte > 0) {
        const rgb = HUE_LUT[speciesByte];
        r = rgb.r; g = rgb.g; b = rgb.b;
        a = 255;
      } else if (showCarcass && carc > 0) {
        if (carcHueByte > 0) {
          const rgb = HUE_LUT[carcHueByte];
          r = rgb.r; g = rgb.g; b = rgb.b;
        } else {
          r = 255; g = 60; b = 60;
        }
        a = Math.min(255, carc * 4);
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
