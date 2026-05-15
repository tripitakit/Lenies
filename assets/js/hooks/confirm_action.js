// ConfirmAction hook: intercepts click events on the element and fires
// window.confirm() before the click propagates to Phoenix LiveView's
// phx-click handler. If the user cancels, the event is stopped.
//
// Two modes:
//   - Unconditional: data-confirm="message" — confirm fires on every click.
//   - Conditional:   data-confirm-when="<selector>" — confirm fires only
//     if document.querySelector(<selector>) matches (e.g.
//     "[data-inspector-dirty='true']" — fire only when the inspector has
//     unsaved edits).
//
// Usage:
//   <button phx-click="cancel_edit"
//           phx-hook="ConfirmAction"
//           data-confirm="Discard codeome edits?"
//           data-confirm-when="[data-inspector-dirty='true']">

const ConfirmAction = {
  mounted() {
    this.handler = (e) => {
      const message = this.el.dataset.confirm;
      if (!message) return;

      const selector = this.el.dataset.confirmWhen;
      if (selector) {
        const source = document.querySelector(selector);
        if (!source) return; // condition not met — let the click through
      }

      if (!window.confirm(message)) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    };

    // Capture phase so this runs before Phoenix's listener.
    this.el.addEventListener("click", this.handler, true);
  },

  destroyed() {
    if (this.handler) {
      this.el.removeEventListener("click", this.handler, true);
    }
  },
};

export default ConfirmAction;
