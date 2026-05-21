// AudioToggle hook: replaces the inline onclick IIFE on the audio-toggle button.
//
// Attach to a button with phx-hook="AudioToggle" and phx-update="ignore".
// On click it toggles window.LeniesAudio mute/unmute and updates the button's
// textContent and dataset.muted to match the inline logic that was removed.
// Guard: if window.LeniesAudio is undefined (audio is decorative) the click is
// a no-op. The initial state is read from LeniesAudio.isMuted() on mount so the
// button always reflects the real mute state at connect time.

const AudioToggle = {
  mounted() {
    this._sync = () => {
      if (!window.LeniesAudio) return;
      if (window.LeniesAudio.isMuted()) {
        this.el.textContent = "∅ MUTE";
        this.el.dataset.muted = "1";
      } else {
        this.el.textContent = "♪ AUDIO";
        this.el.dataset.muted = "";
      }
    };

    // Initialise from current state so the button is correct on connect.
    this._sync();

    this._onClick = () => {
      if (!window.LeniesAudio) return;
      const muted = window.LeniesAudio.isMuted();
      if (muted) {
        window.LeniesAudio.unmute();
      } else {
        window.LeniesAudio.mute();
      }
      this._sync();
    };

    this.el.addEventListener("click", this._onClick);
  },

  destroyed() {
    if (this._onClick) {
      this.el.removeEventListener("click", this._onClick);
    }
  },
};

export default AudioToggle;
