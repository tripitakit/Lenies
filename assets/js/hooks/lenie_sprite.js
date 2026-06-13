// Shared "directional cell" sprite (phenotype language A), used by the
// Arena/Sandbox grid canvas and the Stepper canvas.
//
// Channels:
//   - facing notch  : a light triangle on the facing edge (dir: 'n'|'e'|'s'|'w')
//   - red border    : predator (codeome contains :attack)
//   - white dot     : plasmid carrier
//
// The cell FILL is the caller's responsibility (the grid bakes it into the
// bitmap; the stepper fills before calling). This draws only the overlay
// markers inside `rect` = {x, y, w, h} in device pixels.

export function drawLenieSprite(ctx, rect, { dir, predator, plasmid, notchColor }) {
  const { x, y, w, h } = rect;

  // Facing notch — small triangle pointing out of the facing edge, inset.
  if (dir) {
    const cx = x + w / 2;
    const cy = y + h / 2;
    const s = Math.max(2, Math.min(w, h) * 0.22); // notch half-size
    ctx.fillStyle = notchColor || "rgba(255,255,255,0.85)";
    ctx.beginPath();
    switch (dir) {
      case "n": ctx.moveTo(cx, y + h * 0.12); ctx.lineTo(cx - s, y + h * 0.12 + s); ctx.lineTo(cx + s, y + h * 0.12 + s); break;
      case "s": ctx.moveTo(cx, y + h * 0.88); ctx.lineTo(cx - s, y + h * 0.88 - s); ctx.lineTo(cx + s, y + h * 0.88 - s); break;
      case "e": ctx.moveTo(x + w * 0.88, cy); ctx.lineTo(x + w * 0.88 - s, cy - s); ctx.lineTo(x + w * 0.88 - s, cy + s); break;
      case "w": ctx.moveTo(x + w * 0.12, cy); ctx.lineTo(x + w * 0.12 + s, cy - s); ctx.lineTo(x + w * 0.12 + s, cy + s); break;
    }
    ctx.closePath();
    ctx.fill();
  }

  // Predator rim.
  if (predator) {
    const lw = Math.max(1, Math.min(w, h) * 0.12);
    ctx.lineWidth = lw;
    ctx.strokeStyle = "#ff3b3b";
    ctx.strokeRect(x + lw / 2, y + lw / 2, w - lw, h - lw);
  }

  // Plasmid dot (top-right).
  if (plasmid) {
    const r = Math.max(1, Math.min(w, h) * 0.13);
    ctx.fillStyle = "#ffffff";
    ctx.beginPath();
    ctx.arc(x + w - r * 1.6, y + r * 1.6, r, 0, Math.PI * 2);
    ctx.fill();
  }
}

// Decode the packed meta byte → {dir, predator, plasmid}.
export function decodeMeta(byte) {
  const dir = ["n", "e", "s", "w"][byte & 0x03];
  return { dir, predator: (byte & 0x04) !== 0, plasmid: (byte & 0x08) !== 0 };
}
