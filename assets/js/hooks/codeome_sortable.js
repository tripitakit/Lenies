// CodeomeSortable hook: enables drag-and-drop reorder of codeome blocks in
// the EditorLive listing pane, plus accepts drops from the palette
// (CodeomePalette hook) and snippets (SnippetDrag hook, same SortableJS
// group "codeome").
//
// Uses `pushEvent` (not `pushEventTo`): the hook is attached to a plain
// element inside a LiveView (EditorLive), not a LiveComponent, so there
// is no `[data-phx-component]` ancestor for `pushEventTo` to target.
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
  // in place when the buffer changes. Re-attach defensively if we somehow
  // lost the instance after a re-render.
  updated() {
    if (!this.sortable) this.attach();
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
          this.pushEvent("edit_reorder", {
            from: evt.oldDraggableIndex,
            to: evt.newDraggableIndex,
          });
        }
      },
      onAdd: (evt) => {
        let index = 0;
        let sibling = evt.item.previousElementSibling;
        while (sibling) {
          if (sibling.classList.contains("codeome-block-editable")) index++;
          sibling = sibling.previousElementSibling;
        }

        const snippetId = evt.item?.dataset?.snippetId;
        if (snippetId) {
          this.pushEvent("insert_snippet_at", { id: snippetId, index });
          evt.item.remove();
          return;
        }

        const opcode = evt.item?.dataset?.opcode;
        if (opcode) this.pushEvent("edit_insert", { index, opcode });
        evt.item.remove();
      },
    });
  },
};

export default CodeomeSortable;
