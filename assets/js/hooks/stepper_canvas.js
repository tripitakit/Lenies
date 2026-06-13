import { drawLenieSprite } from "./lenie_sprite.js";
import { drawFx, FX_DURATION_MS } from "./lenie_fx.js";

const StepperCanvas = {
  mounted() {
    this.canvas = document.createElement("canvas");
    this.canvas.style.width = "100%";
    this.canvas.style.height = "100%";
    this.canvas.style.imageRendering = "pixelated";
    this.el.appendChild(this.canvas);
    this.ctx = this.canvas.getContext("2d");

    // State for diff-based birth flashes.
    this.prevIds = new Set();
    this.fx = new Map();

    // Animate active FX between steps (60 ms cadence).
    this.fxTimer = setInterval(() => {
      if (this.fx.size) this.render();
    }, 60);

    this.canvas.addEventListener("click", (e) => {
      const rect = this.canvas.getBoundingClientRect();
      const payload = JSON.parse(this.el.dataset.payload);
      const cellPxX = rect.width / payload.w;
      const cellPxY = rect.height / payload.h;
      const x = Math.max(0, Math.min(payload.w - 1, Math.floor((e.clientX - rect.left) / cellPxX)));
      const y = Math.max(0, Math.min(payload.h - 1, Math.floor((e.clientY - rect.top) / cellPxY)));

      // pushEvent goes straight to EditorLive, which owns the stepper
      // session and handles "stepper:canvas_click" directly. Plain
      // pushEvent (not pushEventTo) is required because the hook lives
      // inside a `phx-update="ignore"` subtree.
      this.pushEvent("stepper:canvas_click", {x, y});
    });

    this.render();
  },

  destroyed() {
    if (this.fxTimer) clearInterval(this.fxTimer);
  },

  updated() { this.render(); },

  render() {
    const payload = JSON.parse(this.el.dataset.payload);
    const cellPx = 16;
    this.canvas.width = payload.w * cellPx;
    this.canvas.height = payload.h * cellPx;

    // Background
    this.ctx.fillStyle = "#050816";
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

    // Resources (green) + carcasses (brown)
    for (const c of payload.cells) {
      if (c.r > 0) {
        // Map alpha across the full baseline range (≈15..45) instead of
        // saturating at r=20, so the per-cell variance is actually visible.
        const alpha = Math.min(1, c.r / 45);
        this.ctx.fillStyle = `rgba(34, 197, 94, ${alpha})`;
        this.ctx.fillRect(c.x * cellPx, c.y * cellPx, cellPx, cellPx);
      }
      if (c.c > 0) {
        const alpha = Math.min(1, c.c / 20);
        this.ctx.fillStyle = `rgba(120, 53, 15, ${alpha})`;
        this.ctx.fillRect(c.x * cellPx, c.y * cellPx, cellPx, cellPx);
      }
    }

    // Lenies — a body square plus the shared directional sprite overlay.
    // Role colours (debug=yellow, seed=violet, child=slate) are the caller's
    // fill; the sprite draws the facing notch + predator/plasmid markers.
    for (const l of payload.lenies) {
      const color =
        l.kind === "debug" ? "#facc15"   // yellow — the one being debugged
        : l.kind === "seed" ? "#a78bfa"  // violet — user-placed seeds
        : "#94a3b8";                     // slate — children
      this.ctx.fillStyle = color;
      this.ctx.fillRect(l.x * cellPx, l.y * cellPx, cellPx, cellPx);

      const rect = { x: l.x * cellPx, y: l.y * cellPx, w: cellPx, h: cellPx };
      drawLenieSprite(this.ctx, rect, {
        dir: l.dir,
        predator: l.predator,
        plasmid: l.plasmid,
        notchColor: "rgba(15,23,42,0.9)",
      });
    }

    // Diff ids → birth flashes (division). Death flashes need the vanished
    // lenie's last cell which isn't tracked post-mortem in the stepper, so
    // only births are flashed here (stepper's share of the vocabulary).
    const now = performance.now();
    const ids = new Set(payload.lenies.map((l) => l.id));
    for (const l of payload.lenies) {
      if (!this.prevIds.has(l.id) && this.prevIds.size > 0) {
        const key = `d:${l.id}:${now}`;
        this.fx.set(key, {
          type: "division",
          x: l.x,
          y: l.y,
          startMs: now,
          expireAt: now + FX_DURATION_MS.division,
        });
      }
    }
    this.prevIds = ids;

    // Draw active FX entries.
    for (const [k, f] of this.fx) {
      if (now >= f.expireAt) { this.fx.delete(k); continue; }
      const p = (now - f.startMs) / (f.expireAt - f.startMs);
      drawFx(this.ctx, f.type, { x: f.x * cellPx, y: f.y * cellPx, w: cellPx, h: cellPx }, p);
    }
  },
};

export default StepperCanvas;
