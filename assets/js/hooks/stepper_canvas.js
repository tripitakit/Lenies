const StepperCanvas = {
  mounted() {
    this.canvas = document.createElement("canvas");
    this.canvas.style.width = "100%";
    this.canvas.style.height = "100%";
    this.canvas.style.imageRendering = "pixelated";
    this.el.appendChild(this.canvas);
    this.ctx = this.canvas.getContext("2d");

    this.canvas.addEventListener("click", (e) => {
      const rect = this.canvas.getBoundingClientRect();
      const payload = JSON.parse(this.el.dataset.payload);
      const cellPxX = rect.width / payload.w;
      const cellPxY = rect.height / payload.h;
      const x = Math.max(0, Math.min(payload.w - 1, Math.floor((e.clientX - rect.left) / cellPxX)));
      const y = Math.max(0, Math.min(payload.h - 1, Math.floor((e.clientY - rect.top) / cellPxY)));

      // Diagnostic — easy to inspect in DevTools console while iterating.
      // Remove once the canvas-click path is verified end-to-end.
      console.log("[stepper] canvas click", {x, y});

      // pushEvent goes to the parent LiveView (EditorLive), which then
      // forwards via send_update to the StepperLive LiveComponent. This
      // is more reliable than pushEventTo with a component selector when
      // the hook is inside a `phx-update="ignore"` subtree.
      this.pushEvent("stepper:canvas_click", {x, y});
    });

    this.render();
  },

  updated() { this.render(); },

  render() {
    const payload = JSON.parse(this.el.dataset.payload);
    const cellPx = 8;
    this.canvas.width = payload.w * cellPx;
    this.canvas.height = payload.h * cellPx;

    // Background
    this.ctx.fillStyle = "#050816";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

    // Resources (green) + carcasses (brown)
    for (const c of payload.cells) {
      if (c.r > 0) {
        const alpha = Math.min(1, c.r / 20);
        this.ctx.fillStyle = `rgba(34, 197, 94, ${alpha})`;
        this.ctx.fillRect(c.x * cellPx, c.y * cellPx, cellPx, cellPx);
      }
      if (c.c > 0) {
        const alpha = Math.min(1, c.c / 20);
        this.ctx.fillStyle = `rgba(120, 53, 15, ${alpha})`;
        this.ctx.fillRect(c.x * cellPx, c.y * cellPx, cellPx, cellPx);
      }
    }

    // Lenies
    for (const l of payload.lenies) {
      const color =
        l.kind === "debug" ? "#facc15"   // yellow — the one being debugged
        : l.kind === "seed" ? "#a78bfa"  // violet — user-placed seeds
        : "#94a3b8";                     // slate — children
      this.ctx.fillStyle = color;
      this.ctx.fillRect(l.x * cellPx, l.y * cellPx, cellPx, cellPx);

      // Facing arrow (tiny triangle at the front edge)
      this.ctx.fillStyle = "#0f172a";
      this.ctx.beginPath();
      const cx = l.x * cellPx + cellPx / 2;
      const cy = l.y * cellPx + cellPx / 2;
      const r = cellPx / 3;
      switch (l.dir) {
        case "n":
          this.ctx.moveTo(cx, cy - r);
          this.ctx.lineTo(cx - r / 2, cy + r / 2);
          this.ctx.lineTo(cx + r / 2, cy + r / 2);
          break;
        case "s":
          this.ctx.moveTo(cx, cy + r);
          this.ctx.lineTo(cx - r / 2, cy - r / 2);
          this.ctx.lineTo(cx + r / 2, cy - r / 2);
          break;
        case "e":
          this.ctx.moveTo(cx + r, cy);
          this.ctx.lineTo(cx - r / 2, cy - r / 2);
          this.ctx.lineTo(cx - r / 2, cy + r / 2);
          break;
        case "w":
          this.ctx.moveTo(cx - r, cy);
          this.ctx.lineTo(cx + r / 2, cy - r / 2);
          this.ctx.lineTo(cx + r / 2, cy + r / 2);
          break;
      }
      this.ctx.closePath();
      this.ctx.fill();
    }
  },
};

export default StepperCanvas;
