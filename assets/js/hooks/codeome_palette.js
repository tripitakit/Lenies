// CodeomePalette hook: enables drag of opcode chips from the palette into
// the codeome listing in EditorLive. Uses SortableJS with `pull: "clone"`
// so the source palette is unaffected by the drag. Drops are received by
// the CodeomeSortable hook on the codeome listing, which fires
// `edit_insert` on the LiveView.
//
// The palette also accepts drops FROM the codeome listing (group put:
// true) — dropping a codeome block onto any palette category fires
// `edit_delete`. And double-clicking a chip appends that opcode to the
// end of the buffer via `edit_insert`. Together this gives three input
// methods: drag-in (insert at position), dblclick (append at end),
// drag-out (delete).
//
// SortableJS reliably handles drag of items that are DIRECT children of the
// Sortable container. Because the palette groups chips by category
// (#palette-grid > .palette-category > .palette-category-chips > .palette-chip),
// we instantiate one Sortable per .palette-category-chips so each chip is a
// direct child of its Sortable root. All instances share group "codeome", so
// drops on the codeome listing work the same as if there were a single source.

import Sortable from "../../vendor/sortable.js";

const CodeomePalette = {
  mounted() {
    this.sortables = [];
    this.el.querySelectorAll(".palette-category-chips").forEach((container) => {
      this.sortables.push(
        Sortable.create(container, {
          group: { name: "codeome", pull: "clone", put: true },
          draggable: ".palette-chip",
          sort: false,
          animation: 120,
          // forceFallback: use SortableJS's DOM-based drag instead of native
          // HTML5 drag. Native drag inside CSS grid containers (and across
          // grid-laid-out modal columns) is unreliable on Chromium and
          // breaks pickup of the source chip. The DOM-based fallback
          // positions a clone via fixed coordinates and works regardless of
          // parent layout. Touch devices also benefit.
          forceFallback: true,
          fallbackOnBody: true,
          fallbackTolerance: 4,
          // Drop FROM the codeome listing onto any palette category =
          // delete that opcode from the buffer. evt.item is the dragged
          // .codeome-block-editable, carrying data-idx with the buffer
          // position. We fire the event and immediately remove the
          // injected DOM node — the next LiveView morph will rebuild the
          // listing without it.
          onAdd: (evt) => {
            const idxAttr = evt.item?.dataset?.idx;
            const section = evt.item?.dataset?.section;
            if (idxAttr !== undefined && section) {
              this.pushEvent("edit_delete", { section, index: idxAttr });
            }
            evt.item.remove();
          },
        }),
      );
    });

    // Double-click a chip = insert that opcode at the caret. The server
    // owns the caret position (and its section), so the hook only needs to
    // forward the opcode.
    this.dblclickHandler = (event) => {
      const chip = event.target.closest(".palette-chip");
      if (!chip || !this.el.contains(chip)) return;
      const opcode = chip.dataset.opcode;
      if (!opcode) return;
      this.pushEvent("edit_insert_at_caret", { opcode });
    };
    this.el.addEventListener("dblclick", this.dblclickHandler);
  },

  destroyed() {
    if (this.sortables) {
      this.sortables.forEach((s) => s.destroy());
      this.sortables = null;
    }
    if (this.dblclickHandler) {
      this.el.removeEventListener("dblclick", this.dblclickHandler);
      this.dblclickHandler = null;
    }
  },
};

export default CodeomePalette;
