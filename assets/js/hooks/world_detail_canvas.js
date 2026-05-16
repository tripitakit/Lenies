// WorldDetailCanvas hook: renders the same render_frame payload as the
// dashboard's GridCanvas hook but at a larger pixel scale and with an
// optional "highlight" filter that dims every pixel whose species byte
// does not match data-highlight-hue.
//
// The highlight byte is read at draw time from the DOM attribute, so
// LiveView re-renders that change data-highlight-hue automatically take
// effect on the next frame without any extra event plumbing.

import { HUE_LUT } from "./grid_canvas_hue_lut.js";

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

    this.handleEvent("render_frame", (payload) => {
      this.lastPayload = payload;
      this.renderFrame();
    });

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
        if (carcHueByte > 0) {
          const rgb = HUE_LUT[carcHueByte];
          r = rgb.r; g = rgb.g; b = rgb.b;
        } else {
          r = 255; g = 60; b = 60;
        }
        a = Math.min(255, carc * 4);
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

    // Nearest-neighbor upscale onto the display canvas.
    this.ctx.imageSmoothingEnabled = false;
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.ctx.drawImage(
      this.bufferCanvas,
      0, 0, this.gridW, this.gridH,
      0, 0, this.canvas.width, this.canvas.height
    );
  },

  destroyed() {
    this.lastPayload = null;
  }
};

export default WorldDetailCanvas;
