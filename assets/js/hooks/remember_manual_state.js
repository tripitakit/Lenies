// RememberManualState hook: at mount, reads localStorage for the user's
// last viewed chapter and last collapse state, and pushes them up so the
// EditorLive can restore the assigns. Subsequent server updates write
// back to localStorage.
//
// Attaches to the editor page root (NOT to the manual pane itself —
// the pane may be unmounted when collapsed).

const RememberManualState = {
  mounted() {
    let chapter = null;
    let collapsed = null;
    try {
      chapter = localStorage.getItem("lenies.manual.lastChapter");
      collapsed = localStorage.getItem("lenies.manual.collapsed");
    } catch (_e) {
      // localStorage unavailable (Safari private mode, disabled storage, etc.) — skip restore
    }

    const payload = {};
    if (chapter) payload.chapter = chapter;
    if (collapsed !== null) payload.collapsed = collapsed === "true";

    if (Object.keys(payload).length > 0) {
      this.pushEvent("restore_manual_state", payload);
    }

    this.handleEvent("persist_manual_state", ({ chapter, collapsed }) => {
      try {
        if (typeof chapter === "string") {
          localStorage.setItem("lenies.manual.lastChapter", chapter);
        }
        if (typeof collapsed === "boolean") {
          localStorage.setItem("lenies.manual.collapsed", String(collapsed));
        }
      } catch (_e) {
        // localStorage unavailable — silently skip persistence
      }
    });
  },
};

export default RememberManualState;
