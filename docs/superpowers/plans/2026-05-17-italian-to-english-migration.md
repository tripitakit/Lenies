# Italian → English Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate every Italian-language string in `lib/` and `test/` to English so the running application is comprehensible in English alone.

**Architecture:** Five batches of in-place translation: codeome/seeds → interpreter → world+core → web+tests → final sweep. Each batch is one git commit verified by `mix compile --warning-as-errors` and the relevant test scope. Domain terminology (`Lenie`, `codeome`, `nop_0`/`nop_1`, opcode names) stays verbatim.

**Tech Stack:** Elixir 1.19 / Phoenix LiveView 1.1. Translation is text-only; no logic or identifier changes.

**Spec:** `docs/superpowers/specs/2026-05-17-italian-to-english-migration.md` — read it first.

---

## Translation conventions (apply to every batch)

- **Translate**: `@moduledoc`, `@doc`, inline `#` comments, HEEx string literals.
- **Preserve**: identifiers (module/function/variable/atom names), Lenies-specific jargon (`Lenie`, `codeome`, `template`, `slot`, `nop_0`/`nop_1`, opcode names), spec section references (`vedi spec §4.2` → `see spec §4.2`).
- **Match tone and length**: terse stays terse; one-liner stays one-liner.
- **No logic edits**: if the only legitimate change is text inside `@moduledoc "..."` / `@doc "..."` / `# ...` / HEEx string literals, leave everything else alone. No reformat, no rename.
- **English style**: match the voice of the existing manual (`docs/manual/*.md`) and project README.

To run mix from any task:

```bash
export PATH="$HOME/.asdf/installs/elixir/1.19.3-otp-28/bin:$HOME/.asdf/installs/erlang/28.1.1/bin:/usr/local/bin:/usr/bin:/bin"
cd /home/patrick/projects/playground/Lenies
```

A Phoenix dev server is running on port 4001 in the background. Do **not** start another one.

---

## Task 1: codeome and seeds (6 files)

**Files to translate (Italian-bearing):**

- `lib/lenies/codeome.ex`
- `lib/lenies/codeome/costs.ex`
- `lib/lenies/codeomes/walker.ex`
- `lib/lenies/codeomes/template_jumper.ex`
- `lib/lenies/codeomes/carnivore.ex`
- `lib/lenies/codeomes/minimal_replicator.ex`

**Note**: `lib/lenies/codeome/opcodes.ex` was checked and contains no Italian — skip it.

- [ ] **Step 1.1: Open each file and translate**

For every file in the list above:
1. Read the file.
2. Identify every Italian-language token: prose in `@moduledoc`, `@doc`, inline `#` comments. The seed files (especially `minimal_replicator.ex`) have many `# ── pos X..Y: italian comment ──` headers — translate each comment to English while keeping the `# ── pos X..Y: ... ──` format.
3. Translate in-place using `Edit` tool calls. Preserve all whitespace, indentation, identifiers, and code structure.
4. Move to the next file.

The `minimal_replicator.ex` moduledoc is the largest single translation in this batch (a long descriptive block at the top of the file). Translate the prose paragraphs into the corresponding English prose, keeping the same Markdown structure (`## Algoritmo`, `## Convenzioni`, `## Energy balance`, etc. → `## Algorithm`, `## Conventions`, `## Energy balance` — the last is already English-ish).

- [ ] **Step 1.2: Verify clean compile**

```bash
mix compile --warning-as-errors 2>&1 | tail -5
```

Expected: no warnings, no errors.

- [ ] **Step 1.3: Smoke-test the affected modules**

```bash
mix test test/lenies/codeome_test.exs test/lenies/codeomes/ 2>&1 | tail -3
```

Expected: all tests pass.

- [ ] **Step 1.4: Confirm no Italian remains**

```bash
grep -nE "[àèéìòù]|\b(della|delle|dei|sono|essere|usata|usato|vedi)\b" \
  lib/lenies/codeome.ex \
  lib/lenies/codeome/costs.ex \
  lib/lenies/codeomes/walker.ex \
  lib/lenies/codeomes/template_jumper.ex \
  lib/lenies/codeomes/carnivore.ex \
  lib/lenies/codeomes/minimal_replicator.ex
```

Expected: no output (no matches).

- [ ] **Step 1.5: Commit**

```bash
git add lib/lenies/codeome.ex \
        lib/lenies/codeome/costs.ex \
        lib/lenies/codeomes/walker.ex \
        lib/lenies/codeomes/template_jumper.ex \
        lib/lenies/codeomes/carnivore.ex \
        lib/lenies/codeomes/minimal_replicator.ex
git commit -m "refactor(i18n): translate codeome + seed modules to English"
```

---

## Task 2: interpreter (3 files)

**Files to translate:**

- `lib/lenies/interpreter.ex`
- `lib/lenies/interpreter/state.ex`
- `lib/lenies/interpreter/template.ex`

- [ ] **Step 2.1: Read each file and translate**

Same procedure as Task 1: translate moduledoc, doc strings, and inline comments. Preserve all identifiers and code.

Key items to expect:
- `interpreter.ex`: long moduledoc describing the dispatch loop; per-clause `# ...` comments explaining each opcode's semantics; references to `spec §4` etc.
- `state.ex`: field-by-field description in moduledoc.
- `template.ex`: explanation of template extraction and complement search, with reference to Tierra-style addressing.

- [ ] **Step 2.2: Verify clean compile**

```bash
mix compile --warning-as-errors 2>&1 | tail -5
```

- [ ] **Step 2.3: Smoke-test the interpreter scope**

```bash
mix test test/lenies/interpreter_test.exs test/lenies/interpreter/ 2>&1 | tail -3
```

Expected: all tests pass.

- [ ] **Step 2.4: Confirm no Italian remains**

```bash
grep -nE "[àèéìòù]|\b(della|delle|dei|sono|essere|esegue|usata)\b" \
  lib/lenies/interpreter.ex \
  lib/lenies/interpreter/state.ex \
  lib/lenies/interpreter/template.ex
```

Expected: no output.

- [ ] **Step 2.5: Commit**

```bash
git add lib/lenies/interpreter.ex lib/lenies/interpreter/
git commit -m "refactor(i18n): translate interpreter modules to English"
```

---

## Task 3: world + core (12 files)

**Files to translate:**

- `lib/lenies/world.ex`
- `lib/lenies/world/cell.ex`
- `lib/lenies/world/child_slots.ex`
- `lib/lenies/world/hotspots.ex`
- `lib/lenies/world/radiation.ex`
- `lib/lenies/world/tables.ex`
- `lib/lenies/mutator.ex`
- `lib/lenies/registry.ex`
- `lib/lenies/lenie.ex`
- `lib/lenies/lenie_supervisor.ex`
- `lib/lenies/telemetry.ex`
- `lib/lenies/config.ex`

**Note**: `lib/lenies/species.ex`, `lib/lenies/species_color.ex`, `lib/lenies/snapshot.ex`, `lib/lenies/seeds.ex`, `lib/lenies/seeds/custom_store.ex`, `lib/lenies/application.ex` were checked and contain no Italian — skip.

- [ ] **Step 3.1: Translate each file**

Same procedure. Largest translations expected in:
- `world.ex` (big moduledoc + many clause-level comments about ETS access and tick handling)
- `lenie.ex` (lifecycle docs)
- `mutator.ex` (description of copy-error and background-mutation strategies)

- [ ] **Step 3.2: Verify clean compile**

```bash
mix compile --warning-as-errors 2>&1 | tail -5
```

- [ ] **Step 3.3: Test the affected scope**

```bash
mix test test/lenies/ 2>&1 | tail -3
```

Expected: all tests pass.

- [ ] **Step 3.4: Confirm no Italian remains**

```bash
grep -nE "[àèéìòù]|\b(della|delle|dei|sono|essere|esegue|usata)\b" \
  lib/lenies/world.ex \
  lib/lenies/world/ \
  lib/lenies/mutator.ex \
  lib/lenies/registry.ex \
  lib/lenies/lenie.ex \
  lib/lenies/lenie_supervisor.ex \
  lib/lenies/telemetry.ex \
  lib/lenies/config.ex
```

Expected: no output.

- [ ] **Step 3.5: Commit**

```bash
git add lib/lenies/world.ex lib/lenies/world/ \
        lib/lenies/mutator.ex lib/lenies/registry.ex \
        lib/lenies/lenie.ex lib/lenies/lenie_supervisor.ex \
        lib/lenies/telemetry.ex lib/lenies/config.ex
git commit -m "refactor(i18n): translate world + core modules to English"
```

---

## Task 4: web layer + tests that depend on UI strings

**Files to translate:**

- `lib/lenies_web/live/dashboard_live.ex`
- `lib/lenies_web/live/controls_panel_component.ex`
- `lib/lenies_web/live/species_live.ex`
- `lib/lenies_web/live/lenie_inspector_live.ex`

**Tests to update in lockstep** (because they assert on UI strings being changed):

- `test/lenies_web/live/dashboard_live_test.exs`
- `test/lenies_web/live/species_live_test.exs`
- `test/lenies_web/live/lenie_inspector_live_test.exs`
- `test/lenies/world_test.exs`

**Note**: other web files (`disassembler.ex`, `grid_renderer.ex`, `codeome_buffer.ex`, `species_inspector_component.ex`, `world_detail_component.ex`, controllers, layouts) were checked and either contain no Italian or only English-ish content already — skip in this batch.

### Required UI string translations

| Italian (current) | English (target) | File |
|---|---|---|
| `▮ Mondo` | `▮ World` | `dashboard_live.ex` |
| `▮ Telemetria — popolazione totale nel tempo` | `▮ Telemetry — total population over time` | `dashboard_live.ex` |
| `Risorse` (label and column) | `Resources` | `dashboard_live.ex` |
| `Carcasse` (label) | `Carcasses` | `dashboard_live.ex` |
| `popolaz.` | `pop.` | `dashboard_live.ex` |
| `risorse` (lowercase telemetry label) | `resources` | `dashboard_live.ex` |
| `carcasse` (lowercase telemetry label) | `carcasses` | `dashboard_live.ex` |
| `Una linea per ciascuna delle top {N} specie correnti (top 20/tick salvate in history).` | `One line per species in the current top {N} (top 20 per tick saved to history).` | `dashboard_live.ex` |
| `▮ Specie top {N} di {M}` | `▮ Top {N} species of {M}` | `dashboard_live.ex` |
| `Sei sicuro?` | `Are you sure?` | `controls_panel_component.ex` |
| `Sì, sterilizza` | `Yes, sterilize` | `controls_panel_component.ex` |
| `Specie: {hash}…` | `Species: {hash}…` | `species_live.ex` |
| `Specie con hash <code>{hash}</code> non trovata (estinta o mai esistita).` | `Species with hash <code>{hash}</code> not found (extinct or never existed).` | `species_live.ex` |
| `(Filogenia SVG-tree e diff con specie sorelle: deferito a un futuro polish.)` | `(Phylogeny SVG-tree and sister-species diff: deferred to a future polish.)` | `species_live.ex` |
| `attive` in `Species — {N} attive` (in `world_detail_component.ex` if not already English) | `active` in `Species — {N} active` | `world_detail_component.ex` (checked: already mixed) |

Any other Italian phrase found during per-file inspection that the table doesn't cover.

### Required test assertion updates

**`test/lenies_web/live/dashboard_live_test.exs`** — three changes:

1. Find the test asserting `"Sei sicuro?"` and change to `"Are you sure?"`:

```elixir
refute render(view) =~ "Sei sicuro?"          # old
refute render(view) =~ "Are you sure?"         # new

assert render(view) =~ "Sei sicuro?"           # old
assert render(view) =~ "Are you sure?"         # new
```

2. Find the test using `element("button", "Sì, sterilizza")` and change:

```elixir
view |> element("button", "Sì, sterilizza") |> render_click()  # old
view |> element("button", "Yes, sterilize") |> render_click()  # new
```

3. Confirm no other Italian-string assertion is in the file. Grep to be sure:

```bash
grep -nE "[àèéìòù]|\b(Sì|sicuro|sterilizza|Specie|Risorse|Carcasse|Mondo|popolaz|Telemetria)\b" \
  test/lenies_web/live/dashboard_live_test.exs
```

**`test/lenies_web/live/species_live_test.exs`** — one change:

Find:
```elixir
assert html =~ ~r/(estinto|empty|nessuno|estinta|mai esistita)/i
```

Replace with:
```elixir
assert html =~ ~r/(extinct|not found|never existed|empty)/i
```

**`test/lenies_web/live/lenie_inspector_live_test.exs`** — read the file and check for any Italian assertion strings. If found, update to match the corresponding UI translation. If none found, no edit needed.

**`test/lenies/world_test.exs`** — read for Italian comments only (these tests don't assert on UI strings). Translate any Italian inline `#` comments.

### Steps

- [ ] **Step 4.1: Translate UI strings + comments in the four web files**

Edit `dashboard_live.ex`, `controls_panel_component.ex`, `species_live.ex`, `lenie_inspector_live.ex`. Apply the table above plus any inline Italian comments found during per-file reading.

- [ ] **Step 4.2: Update the three test files**

Apply the test assertion updates listed above to `dashboard_live_test.exs`, `species_live_test.exs`, `lenie_inspector_live_test.exs`, and `world_test.exs`.

- [ ] **Step 4.3: Verify clean compile**

```bash
mix compile --warning-as-errors 2>&1 | tail -5
```

- [ ] **Step 4.4: Run the web tests**

```bash
mix test test/lenies_web/ 2>&1 | tail -3
```

Expected: all tests pass.

- [ ] **Step 4.5: Run the lenies (world) tests too**

```bash
mix test test/lenies/world_test.exs 2>&1 | tail -3
```

Expected: passes.

- [ ] **Step 4.6: Confirm no Italian remains**

```bash
grep -rnE "[àèéìòù]|\b(Sì|sicuro|sterilizza|Specie|Risorse|Carcasse|Mondo|popolaz|Telemetria|della|delle|dei|sono|essere|esegue|nessun)\b" \
  lib/lenies_web/live/dashboard_live.ex \
  lib/lenies_web/live/controls_panel_component.ex \
  lib/lenies_web/live/species_live.ex \
  lib/lenies_web/live/lenie_inspector_live.ex \
  test/lenies_web/live/dashboard_live_test.exs \
  test/lenies_web/live/species_live_test.exs \
  test/lenies_web/live/lenie_inspector_live_test.exs \
  test/lenies/world_test.exs
```

Expected: no output (no matches).

- [ ] **Step 4.7: Commit**

```bash
git add lib/lenies_web/live/dashboard_live.ex \
        lib/lenies_web/live/controls_panel_component.ex \
        lib/lenies_web/live/species_live.ex \
        lib/lenies_web/live/lenie_inspector_live.ex \
        test/lenies_web/live/dashboard_live_test.exs \
        test/lenies_web/live/species_live_test.exs \
        test/lenies_web/live/lenie_inspector_live_test.exs \
        test/lenies/world_test.exs
git commit -m "refactor(i18n): translate web layer UI + sync test assertions to English"
```

---

## Task 5: final sweep, full suite, push

- [ ] **Step 5.1: Whole-tree Italian scan**

```bash
grep -rnE "[àèéìòù]" lib/ test/ 2>/dev/null | head -30
```

Expected: no output, OR only matches that are legitimate non-Italian (e.g. someone's name in an author tag — unlikely here). If any genuine Italian remains, translate it and commit.

Also broader scan for common Italian function-word patterns that the per-batch greps may have missed:

```bash
grep -rnE "\b(della|delle|dei|sono|essere|esegue|usata|usato|vedi|spec)\b" lib/ test/ 2>/dev/null | \
  grep -v "@spec" | head -30
```

(The `grep -v "@spec"` excludes Elixir `@spec` type annotations from the noise.)

Expected: no output, OR only legitimate uses (e.g. comments that happen to use the English word "are" or "die" — review case-by-case).

- [ ] **Step 5.2: Run the full test suite**

```bash
mix test 2>&1 | tail -3
```

Expected: 367 tests, 0 failures.

- [ ] **Step 5.3: Run mix precommit (the project's official gate)**

```bash
mix precommit 2>&1 | tail -10
```

Expected: clean compile (with `--warning-as-errors`), `mix format` did not need to reformat anything, full test suite green.

- [ ] **Step 5.4: Manual browser smoke test**

Open <http://localhost:4001>. Walk through every clickable surface:

1. Read every label, button, dropdown, and section header in the dashboard. Every visible word must be English.
2. Click **Pause**. Click **Resume**. The button label flip should be English (`Pause` ↔ `Resume`).
3. Click **Sterilize**. The confirm prompt should read `Are you sure?` and the confirm button `Yes, sterilize`.
4. Click on a species row → inspector opens on the right. Every label inside should be English.
5. Click **+ New Seed**. The codeome editor opens. Verify every label, the title `New Seed`, and the inline help text are English.
6. Click **⛶ World detail**. The modal opens. The species list header should read `Species — N active`. Every word in the modal must be English.
7. Navigate to `/species/<some-hash>`. The page should say `Species: <hash>` and (if unknown hash) `Species with hash ... not found (extinct or never existed)`.

If any Italian is visible: identify the file, translate, recompile, re-test, then re-do the smoke test from the start.

- [ ] **Step 5.5: Push**

```bash
git push origin master
```

- [ ] **Step 5.6 (only if step 5.4 found late-discovered Italian)**

Make a final cleanup commit:

```bash
git add <fixed-files>
git commit -m "refactor(i18n): final cleanup of late-discovered Italian content"
git push origin master
```

---

## Self-review (already performed by the plan author)

1. **Spec coverage:**
   - All five batches from the spec are covered (Task 1..5).
   - Translation conventions are at the top of the plan, repeated implicitly per task.
   - Test assertion updates are spelled out in Task 4 with exact before/after code.
   - Definition of done (no Italian remaining, clean compile, all tests green, manual smoke test) is fully covered by Tasks 5.1–5.4.

2. **Placeholder scan:** None. Every step is a concrete `Edit`, `Bash`, or `git` action with the exact commands or strings to apply.

3. **Type / name consistency:**
   - File lists are exhaustive (cross-checked via `grep` survey before writing the plan).
   - UI string mapping table is the single source of truth; tests in Task 4 reference the exact same strings.
   - Verification greps use the same Italian markers in every batch (`[àèéìòù]` plus a curated set of common Italian function words).

4. **Ambiguity:** None — every translation is literal text replacement with a specified before/after pair or, for moduledoc prose, with explicit "translate while keeping structure" instructions.
