// Shared hue-byte → RGB lookup table used by both GridCanvas (dashboard)
// and WorldDetailCanvas (world detail modal).
//
// Hue byte → degrees: deg = (byte - 1) / 255 * 360. Must match
// Lenies.SpeciesColor.byte_to_hex/1 (S=0.70, L=0.55).

const SATURATION = 0.70;
const LIGHTNESS = 0.55;

function hueDegFromByte(b) {
  return ((b - 1) / 255) * 360;
}

// HSL → RGB, returns {r, g, b} as 0..255 ints. Same formula as
// Lenies.SpeciesColor.hsl_to_rgb/3 in Elixir.
function hslToRgb(h, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const hPrime = h / 60;
  const x = c * (1 - Math.abs((hPrime % 2) - 1));

  let r1 = 0, g1 = 0, b1 = 0;
  if (hPrime < 1) { r1 = c; g1 = x; b1 = 0; }
  else if (hPrime < 2) { r1 = x; g1 = c; b1 = 0; }
  else if (hPrime < 3) { r1 = 0; g1 = c; b1 = x; }
  else if (hPrime < 4) { r1 = 0; g1 = x; b1 = c; }
  else if (hPrime < 5) { r1 = x; g1 = 0; b1 = c; }
  else { r1 = c; g1 = 0; b1 = x; }

  const m = l - c / 2;
  return {
    r: Math.round((r1 + m) * 255),
    g: Math.round((g1 + m) * 255),
    b: Math.round((b1 + m) * 255),
  };
}

// Precompute a 256-entry RGB lookup so the per-pixel loop is just a table read.
const HUE_LUT = (() => {
  const lut = new Array(256);
  lut[0] = null; // reserved: "no species"
  for (let b = 1; b < 256; b++) {
    lut[b] = hslToRgb(hueDegFromByte(b), SATURATION, LIGHTNESS);
  }
  return lut;
})();

export { HUE_LUT };
