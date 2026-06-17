// Pure rendering helpers for GridCanvas — no DOM/canvas refs so they can be
// unit-tested under Node (node:assert). Imported by grid_canvas.js (bundled
// by esbuild) and by grid_canvas_render_core.test.mjs (run by node).

// Target presentation period: one frame per world tick (200 ms = 5 fps).
// The renderer can produce no fresher position data than this (the occupancy
// snapshot is written once per ~200 ms tick), so this is the useful ceiling.
export const FRAME_PERIOD_MS = 200;

// Steady-cadence gate: promote a queued frame only once a full period has
// elapsed since the last presentation. Decouples display cadence from the
// jittery arrival times of the network frames.
export function shouldPresent(now, lastPresentAt, periodMs = FRAME_PERIOD_MS) {
  // Treat lastPresentAt === now as "never presented" (both start at the same
  // epoch reference) so the very first call always promotes the frame.
  if (now === lastPresentAt) return true;
  return now - lastPresentAt >= periodMs;
}

function clamp255(v) {
  return v < 0 ? 0 : v > 255 ? 255 : Math.round(v);
}

// Richer energy ramp for a Lenie's species colour. Beyond the old linear
// brightness, low energy desaturates (pulls toward the cell's own grey luma)
// and high energy warms slightly — so adjacent energy levels read apart while
// the species hue family stays recognisable. Returns {r,g,b} 0..255 ints.
// Tunable constants below.
export function energyShade(rgb, energyByte) {
  const n = energyByte / 255; // 0..1
  const bright = 0.22 + 0.78 * Math.pow(n, 0.85);
  let r = rgb.r * bright;
  let g = rgb.g * bright;
  let b = rgb.b * bright;
  const luma = 0.299 * r + 0.587 * g + 0.114 * b;
  const desat = 0.45 * (1 - n); // 0 at full energy, 0.45 at empty
  r += (luma - r) * desat;
  g += (luma - g) * desat;
  b += (luma - b) * desat;
  const warm = 10 * Math.max(0, n - 0.6); // gentle warm push past 60% energy
  r += warm;
  b -= warm;
  return { r: clamp255(r), g: clamp255(g), b: clamp255(b) };
}

// Multi-stop green ramp for the resource field: dark green → vivid green →
// yellow-green near the cap (cap ≈ 3×eat_amount = 150; normalise over ~120 so
// dense cells reach the top of the ramp). Replaces the old flat `g = res*2`.
const RES_STOPS = [
  { t: 0.0, c: { r: 16, g: 54, b: 30 } },
  { t: 0.5, c: { r: 38, g: 170, b: 72 } },
  { t: 1.0, c: { r: 150, g: 208, b: 64 } },
];

function lerp(a, b, t) {
  return a + (b - a) * t;
}

export function resourceColor(resByte) {
  const t = Math.min(1, Math.max(0, resByte / 120));
  let lo = RES_STOPS[0];
  let hi = RES_STOPS[RES_STOPS.length - 1];
  for (let i = 0; i < RES_STOPS.length - 1; i++) {
    if (t >= RES_STOPS[i].t && t <= RES_STOPS[i + 1].t) {
      lo = RES_STOPS[i];
      hi = RES_STOPS[i + 1];
      break;
    }
  }
  const span = hi.t - lo.t || 1;
  const k = (t - lo.t) / span;
  return {
    r: clamp255(lerp(lo.c.r, hi.c.r, k)),
    g: clamp255(lerp(lo.c.g, hi.c.g, k)),
    b: clamp255(lerp(lo.c.b, hi.c.b, k)),
  };
}

// Precompute the 256-entry resource LUT so the per-pixel loop is a table read.
export const RESOURCE_LUT = (() => {
  const lut = new Array(256);
  for (let v = 0; v < 256; v++) lut[v] = resourceColor(v);
  return lut;
})();
