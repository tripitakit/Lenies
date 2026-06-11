// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Bundle version banner — if you do NOT see this log in DevTools console
// the browser is serving a cached version of app.js (hard-refresh or
// disable cache in DevTools Network tab to force reload).
console.log("[Lenies] app.js loaded — build 2026-05-16-debug-3");

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/lenies"
import topbar from "../vendor/topbar"
import GridCanvas from "./hooks/grid_canvas"
import ActionFeedback from "./hooks/action_feedback"
import CodeomeSortable from "./hooks/codeome_sortable"
import ConfirmAction from "./hooks/confirm_action"
import CodeomePalette from "./hooks/codeome_palette"
import RememberManualState from "./hooks/remember_manual_state"
import ManualLinkInterceptor from "./hooks/manual_link_interceptor"
import EditorKeyboard from "./hooks/editor_keyboard"
import AudioToggle from "./hooks/audio_toggle"
import SliderValue from "./hooks/slider_value"
import SnippetDrag from "./hooks/snippet_drag"
import StepperCanvas from "./hooks/stepper_canvas"
import LoopArcs from "./hooks/loop_arcs"
// Landing-page animated background (plain module; no-ops if the canvas is absent).
import "./landing_background"

const Hooks = {GridCanvas, ActionFeedback, CodeomeSortable, ConfirmAction, CodeomePalette, RememberManualState, ManualLinkInterceptor, EditorKeyboard, AudioToggle, SliderValue, SnippetDrag, StepperCanvas, LoopArcs, ...colocatedHooks}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

