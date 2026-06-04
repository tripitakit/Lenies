const StepperFollowIP = {
  scrollToCurrent() {
    const row = this.el.querySelector('[data-current="true"]')
    if (row) row.scrollIntoView({ block: "nearest" })
  },
  mounted() { this.scrollToCurrent() },
  updated() { this.scrollToCurrent() },
}

export default StepperFollowIP
