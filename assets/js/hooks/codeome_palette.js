// CodeomePalette hook: enables drag of opcode chips from the palette into
// the codeome listing in the SpeciesInspectorComponent's edit mode. Uses
// SortableJS with `pull: "clone"` so the source palette is unaffected by
// the drag. Drops are received by the CodeomeSortable hook on the
// codeome listing, which fires `edit_insert` via pushEventTo.

import Sortable from "../../vendor/sortable.js";

const CodeomePalette = {
  mounted() {
    this.sortable = Sortable.create(this.el, {
      group: { name: "codeome", pull: "clone", put: false },
      draggable: ".palette-chip",
      sort: false,
      animation: 120,
    });
  },

  destroyed() {
    if (this.sortable) {
      this.sortable.destroy();
      this.sortable = null;
    }
  },
};

export default CodeomePalette;
