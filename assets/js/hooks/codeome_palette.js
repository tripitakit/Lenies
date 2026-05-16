// CodeomePalette hook: enables drag of opcode chips from the palette into
// the codeome listing in the SpeciesInspectorComponent's edit mode. Uses
// SortableJS with `pull: "clone"` so the source palette is unaffected by
// the drag. Drops are received by the CodeomeSortable hook on the
// codeome listing, which fires `edit_insert` via pushEventTo.
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
    console.log("[CodeomePalette] mounted", {
      id: this.el.id,
      chipContainers: this.el.querySelectorAll(".palette-category-chips").length,
    });
    this.sortables = [];
    this.el.querySelectorAll(".palette-category-chips").forEach((container) => {
      this.sortables.push(
        Sortable.create(container, {
          group: { name: "codeome", pull: "clone", put: false },
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
        }),
      );
    });
  },

  destroyed() {
    console.log("[CodeomePalette] destroyed", { id: this.el.id });
    if (this.sortables) {
      this.sortables.forEach((s) => s.destroy());
      this.sortables = null;
    }
  },
};

export default CodeomePalette;
