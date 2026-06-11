// EditorKeyboard hook: turns clicks and keyboard shortcuts in the codeome
// editor into LiveView events. Click/shift-click on a block body selects;
// global shortcuts drive clipboard/undo/redo/delete/duplicate. Shortcuts are
// suppressed while the user is typing in a text field so native editing works.

const isTextTarget = (el) =>
  !!el &&
  (el.tagName === "INPUT" ||
    el.tagName === "TEXTAREA" ||
    el.tagName === "SELECT" ||
    el.isContentEditable);

const EditorKeyboard = {
  mounted() {
    this.onClick = (e) => {
      // Ignore clicks that start on the drag handle (reorder, not select).
      if (e.target.closest(".codeome-drag-handle")) return;
      // The per-block action buttons (e.g. the ⨯ delete button) carry their
      // own phx-click — clicking them must not also fire select_block.
      if (e.target.closest(".codeome-action-btn")) return;

      const gap = e.target.closest(".codeome-gap");
      if (gap && this.el.contains(gap)) {
        const g = parseInt(gap.dataset.gap, 10);
        const section = gap.dataset.section;
        if (Number.isNaN(g) || !section) return;
        this.pushEvent("place_caret", { section, gap: g, shift: e.shiftKey === true });
        return;
      }

      const block = e.target.closest(".codeome-block-editable");
      if (!block || !this.el.contains(block)) return;
      const idx = parseInt(block.dataset.idx, 10);
      const section = block.dataset.section;
      if (Number.isNaN(idx) || !section) return;
      this.pushEvent("select_block", { section, index: idx, shift: e.shiftKey === true });
    };

    this.onKeydown = (e) => {
      if (isTextTarget(e.target)) return;
      const mod = e.metaKey || e.ctrlKey;
      const key = e.key.toLowerCase();

      if (key === "arrowup" || key === "arrowdown") {
        e.preventDefault();
        const dir = key === "arrowup" ? "up" : "down";
        if (e.altKey) {
          this.pushEvent("move_range_step", { dir });
        } else {
          this.pushEvent("move_caret", { dir, extend: e.shiftKey === true });
        }
        return;
      }
      if (key === "home") { e.preventDefault(); this.pushEvent("move_caret_end", { to: "start" }); return; }
      if (key === "end") { e.preventDefault(); this.pushEvent("move_caret_end", { to: "end" }); return; }

      if (mod && key === "s") {
        e.preventDefault();
        this.pushEvent("open_save_form", {});
        return;
      }

      let event = null;
      if (mod && key === "c") event = "copy_selection";
      else if (mod && key === "x") event = "cut_selection";
      else if (mod && key === "v") event = "paste_clipboard";
      else if (mod && key === "d") event = "duplicate_selection";
      else if (mod && key === "z" && e.shiftKey) event = "redo";
      else if (mod && key === "z") event = "undo";
      else if (mod && key === "y") event = "redo";
      else if (key === "delete" || key === "backspace") event = "delete_selection";
      else if (key === "escape") event = "clear_selection";

      // Don't hijack copy/cut when the user has a native text selection
      // (e.g. selecting text in the manual pane) — let the browser handle it.
      if (
        (event === "copy_selection" || event === "cut_selection") &&
        window.getSelection &&
        window.getSelection().toString() !== ""
      ) {
        return;
      }

      if (event) {
        e.preventDefault();
        this.pushEvent(event, {});
      }
    };

    this.onDblClick = (e) => {
      if (e.target.closest(".codeome-drag-handle")) return;
      if (e.target.closest(".codeome-action-btn")) return;
      const block = e.target.closest(".codeome-block-editable");
      if (!block || !this.el.contains(block)) return;
      const idx = parseInt(block.dataset.idx, 10);
      const section = block.dataset.section;
      if (Number.isNaN(idx) || !section) return;
      this.pushEvent("start_inline_edit", { section, index: idx });
    };
    this.el.addEventListener("dblclick", this.onDblClick);

    this.el.addEventListener("click", this.onClick);
    // keydown binds to `document` (not this.el) so shortcuts work without
    // focusing the grid; removed in destroyed(). Assumes a single
    // EditorKeyboard instance is mounted at a time.
    document.addEventListener("keydown", this.onKeydown);
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick);
    if (this.onKeydown) document.removeEventListener("keydown", this.onKeydown);
    if (this.onDblClick) this.el.removeEventListener("dblclick", this.onDblClick);
    this.onClick = null;
    this.onKeydown = null;
    this.onDblClick = null;
  },
};

export default EditorKeyboard;
