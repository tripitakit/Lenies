// ManualLinkInterceptor hook: rewrites in-content clicks on chapter
// links ([text](04-loops-and-templates.md)) into pushEvent
// select_chapter calls, so cross-chapter navigation works inside the
// manual pane without triggering a full page load.

const ManualLinkInterceptor = {
  mounted() {
    this.handler = (event) => {
      const a = event.target.closest("a[href]");
      if (!a) return;
      const href = a.getAttribute("href");
      if (!href || !href.endsWith(".md")) return;

      event.preventDefault();
      this.pushEvent("select_chapter", { chapter: href });
    };

    this.el.addEventListener("click", this.handler);
  },

  destroyed() {
    if (this.handler) {
      this.el.removeEventListener("click", this.handler);
    }
  },
};

export default ManualLinkInterceptor;
