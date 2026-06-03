// Landing-page animated background.
//
// A self-contained, client-side canvas animation — NOT a LiveView hook (the
// landing has no LiveView, so hooks never mount) and NOT a live simulation (the
// page is public/pre-auth; we must not open a websocket or run a server world
// per visitor). It evokes the Lenies world: a tessellated pure-green resource
// floor (Sandbox tone, intensity-only variation) with small coloured Lenies
// crawling in three movement patterns, leaving dark depletion wakes that slowly
// heal back to the floor.
//
// Auto-initialises on import: if there's no `#landing-bg` canvas on the page
// (i.e. any page other than the landing), it does nothing.

const CELL = 16; // chunky "zoomed map" cells

function boxBlur(src, cols, rows) {
  const out = new Float32Array(src.length);
  for (let y = 0; y < rows; y++) {
    for (let x = 0; x < cols; x++) {
      let s = 0, n = 0;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const X = x + dx, Y = y + dy;
          if (X < 0 || X >= cols || Y < 0 || Y >= rows) continue;
          s += src[Y * cols + X]; n++;
        }
      }
      out[y * cols + x] = s / n;
    }
  }
  return out;
}

function start(canvas) {
  const ctx = canvas.getContext("2d", { alpha: false });
  const reduceMotion =
    window.matchMedia &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  let W, H, COLS, ROWS, base, res, lenies;
  let lastStep = 0, lastFrame = 0, rafId = null;

  function buildGrid() {
    W = canvas.width = Math.max(1, Math.ceil(canvas.clientWidth));
    H = canvas.height = Math.max(1, Math.ceil(canvas.clientHeight));
    COLS = Math.ceil(W / CELL);
    ROWS = Math.ceil(H / CELL);

    // Tessellated floor: coarse smoothed patches (large-scale intensity zones)
    // + strong per-cell jitter (tile-to-tile variability). Intensity only.
    let coarse = new Float32Array(COLS * ROWS);
    for (let i = 0; i < coarse.length; i++) coarse[i] = Math.random();
    coarse = boxBlur(boxBlur(boxBlur(coarse, COLS, ROWS), COLS, ROWS), COLS, ROWS);
    base = new Float32Array(COLS * ROWS);
    for (let i = 0; i < base.length; i++) {
      const patch = 0.06 + coarse[i] * 0.5;
      const jitter = (Math.random() - 0.5) * 0.24;
      base[i] = Math.max(0.02, Math.min(0.62, patch + jitter));
    }
    res = base.slice();

    const n = Math.max(12, Math.round((COLS * ROWS) / 220));
    const patterns = ["forager", "runner", "wanderer"];
    lenies = Array.from({ length: n }, (_, i) => {
      const p = patterns[i % 3];
      return {
        x: Math.random() * COLS,
        y: Math.random() * ROWS,
        ang: Math.random() * 6.2832,
        speed: p === "runner" ? 0.16 : p === "forager" ? 0.09 : 0.06,
        pattern: p,
        hue: Math.floor(Math.random() * 360),
        turnT: 0,
      };
    });
  }

  function stepSim(dt) {
    // Relax slowly toward the floor → wakes refill gradually (persistent).
    for (let i = 0; i < res.length; i++) res[i] += (base[i] - res[i]) * 0.012;

    for (const L of lenies) {
      if (L.pattern === "forager") {
        L.turnT -= dt;
        if (L.turnT <= 0) { L.ang += (Math.random() - 0.5) * 1.6; L.turnT = 200 + Math.random() * 300; }
      } else if (L.pattern === "runner") {
        L.turnT -= dt;
        if (L.turnT <= 0) {
          L.ang += (Math.random() < 0.5 ? 1 : -1) * (Math.PI / 2) * (0.6 + Math.random() * 0.4);
          L.turnT = 1400 + Math.random() * 1800;
        }
      } else {
        L.ang += (Math.random() - 0.5) * 0.5; // wanderer: brownian
      }
      L.x = (L.x + Math.cos(L.ang) * L.speed + COLS) % COLS;
      L.y = (L.y + Math.sin(L.ang) * L.speed + ROWS) % ROWS;
      const idx = (L.y | 0) * COLS + (L.x | 0);
      res[idx] = Math.max(0, res[idx] - 0.4); // eat → dark wake
    }
  }

  function draw() {
    ctx.fillStyle = "#050816";
    ctx.fillRect(0, 0, W, H);
    // Pure green, only the green channel scales with intensity (Sandbox tone).
    for (let y = 0; y < ROWS; y++) {
      for (let x = 0; x < COLS; x++) {
        const r = res[y * COLS + x];
        if (r <= 0.015) continue;
        const g = Math.min(255, Math.round(r * 230));
        ctx.fillStyle = `rgb(0,${g},0)`;
        ctx.fillRect(x * CELL, y * CELL, CELL, CELL);
      }
    }
    for (const L of lenies) {
      const px = (L.x | 0) * CELL, py = (L.y | 0) * CELL;
      ctx.fillStyle = `hsl(${L.hue} 70% 58%)`;
      ctx.shadowColor = `hsl(${L.hue} 80% 60%)`;
      ctx.shadowBlur = 8;
      ctx.fillRect(px, py, CELL, CELL);
    }
    ctx.shadowBlur = 0;
  }

  function loop(t) {
    const dt = Math.min(60, t - lastFrame);
    lastFrame = t;
    if (t - lastStep > 60) { stepSim(t - lastStep); lastStep = t; }
    draw();
    rafId = requestAnimationFrame(loop);
  }

  function play() {
    if (rafId == null && !reduceMotion) {
      lastFrame = lastStep = performance.now();
      rafId = requestAnimationFrame(loop);
    }
  }
  function pause() {
    if (rafId != null) { cancelAnimationFrame(rafId); rafId = null; }
  }

  buildGrid();

  if (reduceMotion) {
    // Static, designed frame: settle a few steps, draw once, never loop.
    for (let i = 0; i < 40; i++) stepSim(60);
    draw();
  } else {
    play();
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) pause(); else play();
  });

  let resizeT = null;
  window.addEventListener("resize", () => {
    clearTimeout(resizeT);
    resizeT = setTimeout(() => {
      buildGrid();
      if (reduceMotion) { for (let i = 0; i < 40; i++) stepSim(60); draw(); }
    }, 200);
  });
}

function init() {
  const canvas = document.getElementById("landing-bg");
  if (canvas) start(canvas);
}

// app.js is a deferred module, so the DOM is parsed by the time this runs.
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
