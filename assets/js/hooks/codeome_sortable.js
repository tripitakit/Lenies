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
    console.log("[CodeomeSortable] mounted", { id: this.el.id, children: this.el.children.length });
    this.attach();
  },

  // LiveView morphdom updates the children of the .codeome-blocks element
  // in place when the buffer changes. SortableJS adapts to the new DOM on
  // the next drag event by re-reading the element list, so we deliberately
  // do nothing here. Tearing down and reattaching on every update would
  // break an in-progress drag.
  updated() {},

  destroyed() {
    console.log("[CodeomeSortable] destroyed", { id: this.el.id });
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
      draggable: ".codeome-block-editable",
      group: { name: "codeome", pull: true, put: true },
      // Increase the pixel radius around an empty container's edge that
      // still counts as "inside" for drop detection. The default of 5px
      // is too tight when the empty .codeome-blocks has a tall flex
      // surface but no children to anchor the insert point.
      emptyInsertThreshold: 20,
      onEnd: (evt) => {
        // SortableJS gives oldDraggableIndex/newDraggableIndex counting only
        // elements matching the `draggable` selector — these correspond
        // exactly to buffer positions because insert slots are filtered out.
        // Gate on from === to so cross-list adds (handled by onAdd) are skipped.
        if (
          evt.from === evt.to &&
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
      onAdd: (evt) => {
        const opcode = evt.item?.dataset?.opcode;
        // SortableJS's `newDraggableIndex` counts only items matching the
        // target's `draggable` selector (`.codeome-block-editable`). The
        // dropped clone is a `.palette-chip`, so newDraggableIndex is
        // unreliable for cross-list adds (often undefined / NaN). Count
        // editable siblings that precede the dropped element instead —
        // that is exactly the buffer index where the opcode should land.
        let index = 0;
        let sibling = evt.item.previousElementSibling;
        while (sibling) {
          if (sibling.classList.contains("codeome-block-editable")) index++;
          sibling = sibling.previousElementSibling;
        }
        // Diagnostic logging — drag&drop has been intermittent across
        // browsers; keep this until the dev confirms the flow end-to-end.
        // Open DevTools → Console to see drop coordinates / opcode / index.
        console.log("[CodeomeSortable] onAdd", { opcode, index, item: evt.item });
        if (opcode) {
          this.pushEventTo(this.el, "edit_insert", { index, opcode });
        }
        evt.item.remove();
      },
    });
  },
};

export default CodeomeSortable;
