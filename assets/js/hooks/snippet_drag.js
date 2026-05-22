import Sortable from "../../vendor/sortable.js";

const SnippetDrag = {
  mounted() {
    this.attach();
  },

  // LiveView morphs the snippet list when snippets change or on a full
  // re-render. Re-attach defensively if we lost the instance after a morph.
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
      group: { name: "codeome", pull: "clone", put: false },
      draggable: ".codeome-snippet-row",
      sort: false,
      forceFallback: true,
      fallbackOnBody: true,
      animation: 120,
    });
  },
};

export default SnippetDrag;
