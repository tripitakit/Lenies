# Codeome Block View (Phase C1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the text codeome listing inside the species inspector with a vertical list of compact, color-accented block tiles.

**Architecture:** Pure template + CSS change. No new modules, no new Elixir logic. The component keeps receiving `codeome_lines` from `LeniesWeb.Disassembler.disassemble/2` and iterates them; each opcode becomes a `<div class="codeome-block op op-<category>">` with index + uppercased name. CSS sets a 3px left accent stripe whose color is inherited from the existing `op-<category>` rule via `currentColor`.

**Tech Stack:** Elixir 1.19, Phoenix LiveView, Tailwind v4 (utility classes already present), vanilla CSS for the new rules.

**Spec:** `docs/superpowers/specs/2026-05-15-codeome-blocks.md`

---

## Task 1: Block-tile rendering + CSS

**Files:**
- Modify: `lib/lenies_web/live/species_inspector_component.ex` (template only — the listing block)
- Modify: `assets/css/app.css` (append `.codeome-block*` rules)
- Modify: `test/lenies_web/live/species_inspector_component_test.exs` (two substring → regex assertions + one new shape assertion)

- [ ] **Step 1: Look at the current state**

Print the current listing block in the component template (you'll replace it in Step 3) and the test file's two `assert html =~ "..."` lines you'll update in Step 4:

```bash
cd /home/patrick/projects/playground/Lenies && \
  grep -n -A 12 'codeome_lines do' lib/lenies_web/live/species_inspector_component.ex && \
  echo '---' && \
  grep -n 'nop_1\|get_size\|font-mono' test/lenies_web/live/species_inspector_component_test.exs
```

The block to replace ends at the closing `<div>` of the `flex-1 min-h-0 overflow-auto` scroll container. The current listing wraps each line in `<div class="text-[10px] leading-tight font-mono">`.

- [ ] **Step 2: Update the assertions in the test file**

In `test/lenies_web/live/species_inspector_component_test.exs`, find the "with a live Lenie of the species" test (the last test in the `describe "fetch behavior"` block). Inside it, change:

```elixir
      assert html =~ "nop_1"
      ...
      assert html =~ "get_size"
```

to:

```elixir
      assert html =~ ~r/nop_1/i
      ...
      assert html =~ ~r/get_size/i
```

Then add **one new test** to the existing `describe "fetch behavior" do` block (after the live-Lenie test):

```elixir
    test "renders codeome lines as block tiles with the codeome-blocks container" do
      codeome = Lenies.Codeomes.MinimalReplicator.codeome()
      hash = Lenies.Codeome.hash(codeome)

      {:ok, _pid} =
        Lenies.Lenie.start_link(
          id: "TEST-BLOCK-L1",
          codeome: codeome,
          energy: 100.0,
          pos: {0, 0},
          dir: :n,
          lineage: {nil, 0}
        )

      :ets.insert(:lenies, {"TEST-BLOCK-L1", %{id: "TEST-BLOCK-L1", codeome_hash: hash}})

      html =
        render_component(SpeciesInspectorComponent, %{
          id: "block-inspector",
          selected_hash: hash,
          species_record: %{hash: hash, population: 1, avg_generation: 0.0}
        })

      assert html =~ ~s(class="codeome-blocks")
      assert html =~ "codeome-block op op-template"
      # idx span padded to 3 chars
      assert html =~ ~s(class="codeome-block-idx")
      # name span exists
      assert html =~ ~s(class="codeome-block-name")
    end
```

- [ ] **Step 3: Run tests to verify the new shape test fails**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: the two existing assertions still pass (regex is rendering-agnostic), and the new "renders codeome lines as block tiles" test fails because the template doesn't yet emit `codeome-blocks` / `codeome-block-idx` / `codeome-block-name`.

- [ ] **Step 4: Replace the listing block in the component template**

In `lib/lenies_web/live/species_inspector_component.ex`, find this block (inside `render/1`):

```heex
      <div class="flex-1 min-h-0 overflow-auto">
        <div class="text-[10px] leading-tight font-mono">
          <%= for line <- @codeome_lines do %>
            <div class="flex gap-2">
              <span class="opacity-50 tabular-nums w-8 shrink-0">
                {String.pad_leading(Integer.to_string(line.index), 3, " ")}
              </span>
              <span class={"op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
                {Atom.to_string(line.opcode)}
              </span>
            </div>
          <% end %>
        </div>
      </div>
```

Replace with:

```heex
      <div class="flex-1 min-h-0 overflow-auto">
        <div class="codeome-blocks">
          <%= for line <- @codeome_lines do %>
            <div class={"codeome-block op op-" <> Atom.to_string(Disassembler.opcode_class(line.opcode))}>
              <span class="codeome-block-idx">
                {String.pad_leading(Integer.to_string(line.index), 3, "0")}
              </span>
              <span class="codeome-block-name">
                {Atom.to_string(line.opcode) |> String.upcase()}
              </span>
            </div>
          <% end %>
        </div>
      </div>
```

Key differences:

- Outer wrapper: `text-[10px] leading-tight font-mono` → `codeome-blocks` (the per-block CSS now carries font/size).
- Per-line wrapper: `flex gap-2` → `codeome-block op op-<category>` (the category class is reused as the source of `currentColor` for the accent stripe).
- Index padding character: `" "` (space) → `"0"` (zero-pad — visually consistent with the tiles).
- Opcode name spans gain class `codeome-block-name`; index spans gain class `codeome-block-idx`.
- Opcode name is uppercased via `String.upcase/1`.

- [ ] **Step 5: Append the CSS rules**

In `assets/css/app.css`, find the existing block of `op-*` color rules (the 11 lines added in Phase B Task 1, currently between the existing dashboard rules and the closing `/* This file is for your main application CSS */` comment). Append the new `codeome-block*` rules immediately after the 11 `op-*` rules (keeping the closing comment last):

```css
/* ----- Lenies dashboard: codeome block view ----- */
.lenies-dashboard .codeome-blocks {
  display: flex;
  flex-direction: column;
  gap: 1px;
}

.lenies-dashboard .codeome-block {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 1px 6px;
  font-family: ui-monospace, "JetBrains Mono", "Fira Code", monospace;
  font-size: 10px;
  line-height: 1.3;
  border-left: 3px solid currentColor;
  background: rgba(15, 23, 42, 0.4);
  transition: background 80ms ease;
}

.lenies-dashboard .codeome-block:hover {
  background: rgba(34, 211, 238, 0.08);
}

.lenies-dashboard .codeome-block-idx {
  opacity: 0.4;
  width: 24px;
  flex-shrink: 0;
  text-align: right;
  color: #94a3b8;
}

.lenies-dashboard .codeome-block-name {
  font-weight: 600;
  letter-spacing: 0.05em;
}
```

- [ ] **Step 6: Run the inspector tests**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test test/lenies_web/live/species_inspector_component_test.exs
```

Expected: 8 tests pass (the original 7 + the new block-tile shape test).

- [ ] **Step 7: Run the full suite with deterministic seed**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test --seed 0
```

Expected: 263 tests, 0 failures (262 prior + 1 new in this task). Known intermittent test-isolation flakes (in `world_action_test.exs` / `Lenies.TelemetryTest`) are seed-dependent and surface only on random seeds — `--seed 0` is the canonical pass-or-fail signal.

- [ ] **Step 8: Compile clean**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix compile --warnings-as-errors
```

Expected: exit 0, no warnings.

- [ ] **Step 9: Visual smoke check in the browser**

The dev server should already be running.

1. Open the dashboard.
2. Spawn ~5 of any seed (e.g. Minimal Replicator). Wait for the species table to populate.
3. Click a row in the species table — the inspector opens.
4. Confirm the codeome listing now appears as a vertical list of color-accented block tiles:
   - Each row has a colored left edge (3px wide) matching the opcode category color.
   - Opcode names are uppercased (e.g. `NOP_1`, `GET_SIZE`).
   - Indexes are zero-padded 3-char numbers in a faint gray.
   - Hovering a row tints it faintly cyan.
5. Scroll through the codeome — it should be smoother to read than the old text listing.
6. Click `↗` — the standalone `/species/:hash` page still uses the old text rendering (we did not change that view). Confirm it still works.
7. Click `×` — the inspector closes.

If any of those fail, stop and report. The only acceptable difference from the pre-C1 state is the codeome listing itself; the rest of the inspector (header, stats, no-sample notice, close button, ↗ link) is unchanged.

- [ ] **Step 10: Commit**

```bash
git add lib/lenies_web/live/species_inspector_component.ex \
        assets/css/app.css \
        test/lenies_web/live/species_inspector_component_test.exs
git commit -m "feat: codeome block view (C1) — color-accented block tiles in inspector"
```

---

## Final sweep

- [ ] **Step 1: Re-run full suite with deterministic seed**

```bash
export PATH="/home/patrick/.asdf/shims:$PATH" && mix test --seed 0
```

Expected: 263 tests, 0 failures.

- [ ] **Step 2: Confirm no leftover references to the old listing markup**

```bash
cd /home/patrick/projects/playground/Lenies && \
  grep -n 'text-\[10px\] leading-tight font-mono' lib/lenies_web/live/species_inspector_component.ex
```

Expected: no matches (the class string lived only in the block we replaced).

- [ ] **Step 3: Visual smoke check (repeat from Task 1 Step 9)**

Final hands-on confirmation before declaring C1 done.
