// ActionFeedback hook: gives every interactive control an immediate
// audio + visual response, decoupled from the server round-trip.
//
// Attach to any element with phx-hook="ActionFeedback" and data-fx="<variant>".
// Variants:
//   danger   — alarming low burst (sterilize, destructive actions)
//   pause    — descending blip (pause world)
//   resume   — ascending blip (resume world)
//   success  — short bell (spawn, save snapshot)
//   info     — single soft blip (everything else)
//
// Audio is generated via Web Audio API — no asset bundle, no network.
// The AudioContext is lazily constructed on the first user gesture, which
// is required by browser autoplay policies.

let sharedCtx = null;
let muted = false;

const getCtx = () => {
  if (sharedCtx) return sharedCtx;
  try {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    sharedCtx = Ctx ? new Ctx() : null;
  } catch (_) {
    sharedCtx = null;
  }
  return sharedCtx;
};

// Allow runtime mute via window.LeniesAudio.mute()/unmute() from devtools.
window.LeniesAudio = {
  mute: () => { muted = true; },
  unmute: () => { muted = false; },
  isMuted: () => muted,
};

const playTone = (ctx, { freq, endFreq = null, type = "sine", duration = 0.12, gain = 0.08 }) => {
  const now = ctx.currentTime;
  const osc = ctx.createOscillator();
  const g = ctx.createGain();
  osc.type = type;
  osc.frequency.setValueAtTime(freq, now);
  if (endFreq !== null) {
    osc.frequency.exponentialRampToValueAtTime(Math.max(1, endFreq), now + duration);
  }
  g.gain.setValueAtTime(0.0001, now);
  g.gain.exponentialRampToValueAtTime(gain, now + 0.008);
  g.gain.exponentialRampToValueAtTime(0.0001, now + duration);
  osc.connect(g).connect(ctx.destination);
  osc.start(now);
  osc.stop(now + duration + 0.02);
};

const playNoise = (ctx, { duration = 0.2, gain = 0.12 }) => {
  const now = ctx.currentTime;
  const bufferSize = Math.floor(ctx.sampleRate * duration);
  const buffer = ctx.createBuffer(1, bufferSize, ctx.sampleRate);
  const data = buffer.getChannelData(0);
  for (let i = 0; i < bufferSize; i++) {
    // exponentially-decaying noise
    data[i] = (Math.random() * 2 - 1) * Math.exp(-3 * (i / bufferSize));
  }
  const src = ctx.createBufferSource();
  const g = ctx.createGain();
  const filt = ctx.createBiquadFilter();
  filt.type = "lowpass";
  filt.frequency.value = 600;
  g.gain.value = gain;
  src.buffer = buffer;
  src.connect(filt).connect(g).connect(ctx.destination);
  src.start(now);
};

const FX = {
  danger(ctx) {
    playTone(ctx, { freq: 220, endFreq: 80, type: "sawtooth", duration: 0.32, gain: 0.12 });
    playNoise(ctx, { duration: 0.3, gain: 0.08 });
  },
  pause(ctx) {
    playTone(ctx, { freq: 660, endFreq: 320, type: "triangle", duration: 0.16, gain: 0.09 });
  },
  resume(ctx) {
    playTone(ctx, { freq: 320, endFreq: 660, type: "triangle", duration: 0.16, gain: 0.09 });
  },
  success(ctx) {
    playTone(ctx, { freq: 660, type: "sine", duration: 0.1, gain: 0.08 });
    setTimeout(() => playTone(ctx, { freq: 988, type: "sine", duration: 0.12, gain: 0.08 }), 70);
  },
  info(ctx) {
    playTone(ctx, { freq: 880, type: "sine", duration: 0.06, gain: 0.06 });
  },
};

const playFx = (variant) => {
  if (muted) return;
  const ctx = getCtx();
  if (!ctx) return;
  if (ctx.state === "suspended") ctx.resume();
  const fn = FX[variant] || FX.info;
  try {
    fn(ctx);
  } catch (_) {
    /* swallow — audio is decorative */
  }
};

const pingClass = (variant) =>
  variant === "danger" ? "fx-ping-danger" : "fx-ping";

const ActionFeedback = {
  mounted() {
    this._onPointerDown = (event) => {
      if (event.button !== undefined && event.button !== 0) return;
      const variant = this.el.dataset.fx || "info";
      playFx(variant);
      const cls = pingClass(variant);
      this.el.classList.remove(cls);
      // force reflow so the animation restarts even on rapid repeat clicks
      // eslint-disable-next-line no-unused-expressions
      this.el.offsetWidth;
      this.el.classList.add(cls);
    };
    this.el.addEventListener("pointerdown", this._onPointerDown);
  },

  destroyed() {
    if (this._onPointerDown) {
      this.el.removeEventListener("pointerdown", this._onPointerDown);
    }
  },
};

export default ActionFeedback;
