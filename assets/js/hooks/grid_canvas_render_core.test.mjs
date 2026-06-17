import assert from "node:assert/strict";
import {
  FRAME_PERIOD_MS,
  shouldPresent,
  energyShade,
  resourceColor,
  RESOURCE_LUT,
} from "./grid_canvas_render_core.mjs";

// --- shouldPresent: steady-cadence gate ---
assert.equal(shouldPresent(0, 0, FRAME_PERIOD_MS), true, "present first frame at t=0");
assert.equal(shouldPresent(100, 0, 200), false, "hold before the period elapses");
assert.equal(shouldPresent(200, 0, 200), true, "present once the period elapses");
assert.equal(shouldPresent(250, 200, 200), false, "hold within the next period");

// --- energyShade: bounded, monotonic brightness, preserves hue family ---
const base = { r: 70, g: 211, b: 154 };
const lo = energyShade(base, 0);
const hi = energyShade(base, 255);
for (const c of [lo, hi]) {
  for (const ch of ["r", "g", "b"]) {
    assert.ok(c[ch] >= 0 && c[ch] <= 255, "channel in 0..255");
    assert.ok(Number.isInteger(c[ch]), "channel is integer");
  }
}
const lumaLo = 0.299 * lo.r + 0.587 * lo.g + 0.114 * lo.b;
const lumaHi = 0.299 * hi.r + 0.587 * hi.g + 0.114 * hi.b;
assert.ok(lumaHi > lumaLo, "higher energy is brighter");
// low energy is more desaturated (channels closer together) than high energy
const spread = (c) => Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b);
assert.ok(spread(hi) > spread(lo), "low energy is more desaturated");

// --- resourceColor / RESOURCE_LUT: 256 entries, green-dominant, brighter w/ more resource ---
assert.equal(RESOURCE_LUT.length, 256, "LUT has 256 entries");
for (const v of RESOURCE_LUT) {
  assert.ok(v.g >= v.r && v.g >= v.b, "green channel dominates");
}
const rLo = resourceColor(10);
const rHi = resourceColor(120);
assert.ok(rHi.g + rHi.r > rLo.g + rLo.r, "more resource is brighter");
assert.deepEqual(RESOURCE_LUT[37], resourceColor(37), "LUT matches builder");

console.log("grid_canvas_render_core: all assertions passed");
