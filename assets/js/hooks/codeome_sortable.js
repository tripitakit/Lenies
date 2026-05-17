// CodeomeSortable hook: enables drag-and-drop reorder of codeome blocks in
// the EditorLive listing pane. On drop, emits an `edit_reorder` event
// to the parent LiveView with the from/to indices.
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
  // in place when the buffer changes. SortableJS normally adapts to the
  // new DOM on the next drag event, but in two edge cases the Sortable
  // instance gets out of sync and silently rejects drops:
  //   1. Closing the editor (cancel/save) and reopening it on a different
  //      flow can leave the previous Sortable still bound to the same DOM
  //      element if Phoenix doesn't fire destroyed()/mounted().
  //   2. enter_edit → buffer suddenly has N children where it had 0, and
  //      SortableJS's cached child list goes stale.
  // Re-attach defensively if we somehow lost the instance.
  updated() {
    console.log("[CodeomeSortable] updated", { id: this.el.id, hasSortable: !!this.sortable, children: this.el.children.length });
    if (!this.sortable) this.attach();
  },

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
      // Explicitly accept every move into this sortable. SortableJS's
      // default `onMove` returns `true`, but being explicit means cross-
      // list adds from the palette (which carry a `.palette-chip` class,
      // not matching this sortable's `draggable` selector) are guaranteed
      // not to be silently rejected by any future option tweak.
      onMove: () => true,
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
          // pushEvent (not pushEventTo): the hook is attached to a plain
          // element inside a LiveView (EditorLive), not a LiveComponent,
          // so there is no [data-phx-component] ancestor for pushEventTo
          // to target — it would silently drop the event.
          this.pushEvent("edit_reorder", {
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
        if (opcode) {
          this.pushEvent("edit_insert", { index, opcode });
        }
        evt.item.remove();
      },
    });
  },
};

export default CodeomeSortable;
