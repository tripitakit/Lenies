// EditorKeyboard hook: turns clicks and keyboard shortcuts in the codeome
// editor into LiveView events. Click/shift-click on a block body selects;
// global shortcuts drive clipboard/undo/redo/delete/duplicate. Shortcuts are
// suppressed while the user is typing in a text field so native editing works.

const isTextTarget = (el) =>
  !!el &&
  (el.tagName === "INPUT" ||
    el.tagName === "TEXTAREA" ||
    el.isContentEditable);

const EditorKeyboard = {
  mounted() {
    this.onClick = (e) => {
      // Ignore clicks that start on the drag handle (reorder, not select).
      if (e.target.closest(".codeome-drag-handle")) return;
      const block = e.target.closest(".codeome-block-editable");
      if (!block || !this.el.contains(block)) return;
      const idx = parseInt(block.dataset.idx, 10);
      if (Number.isNaN(idx)) return;
      this.pushEvent("select_block", { index: idx, shift: e.shiftKey === true });
    };

    this.onKeydown = (e) => {
      if (isTextTarget(e.target)) return;
      const mod = e.metaKey || e.ctrlKey;
      const key = e.key.toLowerCase();

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

      if (event) {
        e.preventDefault();
        this.pushEvent(event, {});
      }
    };

    this.el.addEventListener("click", this.onClick);
    document.addEventListener("keydown", this.onKeydown);
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick);
    if (this.onKeydown) document.removeEventListener("keydown", this.onKeydown);
    this.onClick = null;
    this.onKeydown = null;
  },
};

export default EditorKeyboard;
