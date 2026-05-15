// CodeomeSortable hook: enables drag-and-drop reorder of codeome blocks in
// the SpeciesInspectorComponent's edit mode. On drop, emits an
// `edit_reorder` event to the component with the from/to indices.
//
// Driven by vendored SortableJS (assets/vendor/sortable.js). Phoenix
// LiveView re-renders after the event applies the mutation; SortableJS's
// own DOM mutation during drag is replaced by LiveView's morphed DOM, but
// the visible result is the same because the buffer ordering matches the
// dropped position.

import Sortable from "../../vendor/sortable.js";

const CodeomeSortable = {
  mounted() {
    this.attach();
  },

  updated() {
    // Re-attach if the underlying list element was replaced.
    if (!this.sortable || !this.el.isConnected) {
      this.attach();
    }
  },

  destroyed() {
    if (this.sortable) {
      this.sortable.destroy();
      this.sortable = null;
    }
  },

  attach() {
    if (this.sortable) this.sortable.destroy();

    this.sortable = Sortable.create(this.el, {
      animation: 120,
      handle: ".codeome-drag-handle",
      ghostClass: "codeome-block-ghost",
      filter: ".codeome-insert-slot",
      preventOnFilter: false,
      draggable: ".codeome-block-editable",
      onEnd: (evt) => {
        // SortableJS gives oldDraggableIndex/newDraggableIndex counting only
        // elements matching the `draggable` selector — these correspond
        // exactly to buffer positions because insert slots are filtered out.
        if (
          typeof evt.oldDraggableIndex === "number" &&
          typeof evt.newDraggableIndex === "number" &&
          evt.oldDraggableIndex !== evt.newDraggableIndex
        ) {
          this.pushEventTo(this.el, "edit_reorder", {
            from: evt.oldDraggableIndex,
            to: evt.newDraggableIndex,
          });
        }
      },
    });
  },
};

export default CodeomeSortable;
