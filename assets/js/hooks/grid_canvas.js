// GridCanvas hook: renders 3 layers (lenies, resource, carcass) on a 2D canvas.
// Receives base64-encoded binary layers via phx event "render_frame".
//
// Layer encoding (1 byte per cell, row-major):
//   - lenies: 1 if cell occupied, else 0
//   - resource: 0..100
//   - carcass: 0..50
//
// Color composition:
//   - resource → green channel
//   - carcass → red channel
//   - lenies → high-alpha blue overlay

const GridCanvas = {
  mounted() {
    this.canvas = this.el;
    this.ctx = this.canvas.getContext("2d");
    this.gridW = parseInt(this.canvas.dataset.gridWidth, 10);
    this.gridH = parseInt(this.canvas.dataset.gridHeight, 10);

    // Off-screen buffer at native grid resolution; scaled to canvas size on draw
    this.bufferCanvas = document.createElement("canvas");
    this.bufferCanvas.width = this.gridW;
    this.bufferCanvas.height = this.gridH;
    this.bufferCtx = this.bufferCanvas.getContext("2d");

    this.handleEvent("render_frame", (payload) => {
      this.renderFrame(payload);
    });

    // Initial clear
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

  updated() {
    // Re-read layer visibility from data attributes (handled in renderFrame on next event)
  },

  decodeBase64(b64) {
    const binStr = atob(b64);
    const len = binStr.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      bytes[i] = binStr.charCodeAt(i);
    }
    return bytes;
  },

  renderFrame({ lenies, resource, carcass, width, height }) {
    const lBytes = this.decodeBase64(lenies);
    const rBytes = this.decodeBase64(resource);
    const cBytes = this.decodeBase64(carcass);

    const showLenies = this.canvas.hasAttribute("data-show-lenies");
    const showResource = this.canvas.hasAttribute("data-show-resource");
    const showCarcass = this.canvas.hasAttribute("data-show-carcass");

    const imageData = this.bufferCtx.createImageData(width, height);
    const px = imageData.data; // RGBA, length = w*h*4

    for (let i = 0; i < width * height; i++) {
      const lenie = lBytes[i];
      const res = rBytes[i];
      const carc = cBytes[i];

      // Scale: resource 0..100 → 0..200 in green; carcass 0..50 → 0..200 in red
      const g = showResource ? Math.min(255, res * 2) : 0;
      const r = showCarcass ? Math.min(255, carc * 4) : 0;
      const b = showLenies && lenie > 0 ? 255 : 0;
      const a = showLenies && lenie > 0 ? 255 : 192;

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
