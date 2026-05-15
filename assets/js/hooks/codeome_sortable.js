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

  // LiveView morphdom updates the children of the .codeome-blocks element
  // in place when the buffer changes. SortableJS adapts to the new DOM on
  // the next drag event by re-reading the element list, so we deliberately
  // do nothing here. Tearing down and reattaching on every update would
  // break an in-progress drag.
  updated() {},

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
          // pushEventTo accepts a DOM element and walks up to the nearest
          // [data-phx-component] ancestor — here the <aside> root of
          // SpeciesInspectorComponent — so the event is routed to that
          // component's handle_event("edit_reorder", ...) clause.
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
