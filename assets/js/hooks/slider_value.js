// SliderValue hook: replaces the inline oninput on tuning sliders.
//
// Attach to a range input with phx-hook="SliderValue" and a
// data-value-target attribute whose value is the id of the display element to
// update (e.g. data-value-target="val-radiation_per_tick").
//
// On input the display element's textContent is set to the slider's current
// value.  The display is also initialised once on mount so it is correct even
// before the user interacts.  The listener is cleaned up in destroyed().

const SliderValue = {
  mounted() {
    this._onInput = () => {
      const targetId = this.el.dataset.valueTarget;
      if (!targetId) return;
      const display = document.getElementById(targetId);
      if (display) display.textContent = this.el.value;
    };

    // Initialise the display from the current slider value on mount.
    this._onInput();

    this.el.addEventListener("input", this._onInput);
  },

  destroyed() {
    if (this._onInput) {
      this.el.removeEventListener("input", this._onInput);
    }
  },
};

export default SliderValue;
