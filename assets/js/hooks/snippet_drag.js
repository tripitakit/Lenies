import Sortable from "../../vendor/sortable.js";

const SnippetDrag = {
  mounted() {
    this.sortable = Sortable.create(this.el, {
      group: { name: "codeome", pull: "clone", put: false },
      draggable: ".codeome-snippet-row",
      sort: false,
      forceFallback: true,
      fallbackOnBody: true,
      animation: 120,
    });
  },
  destroyed() {
    if (this.sortable) this.sortable.destroy();
  },
};

export default SnippetDrag;
