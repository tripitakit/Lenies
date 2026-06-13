// Typed event-flash animations drawn over the world canvas. Each entry is
// {type, gx, gy, startMs, expireAt}. `drawFx` renders one entry given the
// cell's device-pixel rect and the normalised progress 0..1.

export const FX_DURATION_MS = {
  conjugation: 3000,
  division: 700,
  death: 900,
  predation: 500,
};

export function drawFx(ctx, type, rect, progress) {
  const { x, y, w, h } = rect;
  const cx = x + w / 2;
  const cy = y + h / 2;

  switch (type) {
    case "division": {
      // Expanding green ring ("life" colour), fading out.
      const rr = (w / 2) * (0.4 + progress * 1.8);
      ctx.globalAlpha = 1 - progress;
      ctx.strokeStyle = "rgba(90, 230, 130, 1)";
      ctx.lineWidth = Math.max(1, w * 0.12);
      ctx.beginPath();
      ctx.arc(cx, cy, rr, 0, Math.PI * 2);
      ctx.stroke();
      ctx.globalAlpha = 1;
      break;
    }
    case "death": {
      // Grey shrink-puff.
      const rr = (w / 2) * (0.4 + progress * 1.6);
      ctx.globalAlpha = (1 - progress) * 0.9;
      ctx.strokeStyle = "rgba(154, 160, 168, 1)";
      ctx.lineWidth = Math.max(1, w * 0.1);
      ctx.beginPath();
      ctx.arc(cx, cy, rr, 0, Math.PI * 2);
      ctx.stroke();
      ctx.globalAlpha = 1;
      break;
    }
    case "predation": {
      // Red impact square, sharp fade.
      ctx.globalAlpha = (1 - progress) * 0.85;
      ctx.fillStyle = "#ff3b3b";
      ctx.fillRect(x, y, w, h);
      ctx.globalAlpha = 1;
      break;
    }
    case "conjugation":
    default: {
      // Existing yellow-white flash.
      ctx.globalAlpha = (1 - progress) * 0.8;
      ctx.fillStyle = "rgb(255, 255, 200)";
      ctx.fillRect(x, y, w, h);
      ctx.globalAlpha = 1;
      break;
    }
  }
}
