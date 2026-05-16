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
    this.sortables = [];
    this.el.querySelectorAll(".palette-category-chips").forEach((container) => {
      this.sortables.push(
        Sortable.create(container, {
          group: { name: "codeome", pull: "clone", put: false },
          draggable: ".palette-chip",
          sort: false,
          animation: 120,
        }),
      );
    });
  },

  destroyed() {
    if (this.sortables) {
      this.sortables.forEach((s) => s.destroy());
      this.sortables = null;
    }
  },
};

export default CodeomePalette;
