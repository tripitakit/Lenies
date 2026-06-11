// LoopArcs hook: draws backward-jump (loop) arcs in a gutter SVG beside the
// sectioned codeome listing. The server can't know row pixel positions
// (blocks wrap, sections add dividers), so the client measures each
// [data-flat] row and draws a bracket path per loop. Re-measures on every
// LiveView update and on resize.
//
// It also absorbs the old StepperFollowIP behavior (two hooks can't share one
// element): at the end of draw() it scrolls the current IP row into view.
//
// Element contract:
//   this.el            — the listing container (#codeome-listing)
//   data-loops         — JSON [[jumpFlat, targetFlat], ...]
//   data-ip            — current ip (or absent), for the active-arc class
//   <svg class="codeome-loop-gutter"> — first child, absolutely positioned
const LoopArcs = {
  mounted() {
    this.draw();
    this.onResize = () => this.draw();
    window.addEventListener("resize", this.onResize);
  },
  updated() {
    this.draw();
  },
  destroyed() {
    window.removeEventListener("resize", this.onResize);
  },
  draw() {
    const svg = this.el.querySelector("svg.codeome-loop-gutter");
    if (!svg) return;
    let loops = [];
    try {
      loops = JSON.parse(this.el.dataset.loops || "[]");
    } catch (_e) {
      loops = [];
    }
    const ip = parseInt(this.el.dataset.ip ?? "-1", 10);
    svg.innerHTML = "";

    if (loops.length) {
      const rowMid = (flat) => {
        const row = this.el.querySelector(`[data-flat='${flat}']`);
        if (!row) return null;
        const r = row.getBoundingClientRect();
        return (
          r.top +
          r.height / 2 -
          this.el.getBoundingClientRect().top +
          this.el.scrollTop
        );
      };

      loops.forEach(([jump, target], lane) => {
        const y1 = rowMid(target);
        const y2 = rowMid(jump);
        if (y1 == null || y2 == null) return;
        const arm = 12;
        const x = 20 - Math.min(lane, 4) * 4;
        const active = target <= ip && ip <= jump;
        const path = document.createElementNS(
          "http://www.w3.org/2000/svg",
          "path",
        );
        path.setAttribute("d", `M ${x + arm} ${y1} H ${x} V ${y2} H ${x + arm}`);
        path.setAttribute(
          "class",
          "stepper-loop-arc" + (active ? " stepper-loop-arc--active" : ""),
        );
        svg.appendChild(path);
      });
    }

    const current = this.el.querySelector("[data-current='true']");
    if (current) current.scrollIntoView({ block: "nearest" });
  },
};

export default LoopArcs;
