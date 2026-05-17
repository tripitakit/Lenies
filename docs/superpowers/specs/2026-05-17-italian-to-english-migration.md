# Italian → English Migration — Design Spec

**Date**: 2026-05-17
**Status**: Approved

## Goal

Translate every Italian-language string in the executable application
(`lib/` and `test/`) to English so the whole running app — source comments,
moduledocs, function docs, inline comments, UI strings, and test
assertions — is comprehensible in English alone, with no Italian content
remaining.

## Scope

**In scope:**

- `lib/lenies/` (~17 files with Italian content): moduledocs, `@doc`
  annotations, inline `#` comments.
- `lib/lenies_web/` (~13 files): same, plus rendered UI strings inside
  HEEx templates.
- `test/` (~2 files): Italian comments and test-assertion strings that
  reference rendered UI strings the migration changes.

**Out of scope:**

- `docs/manual/` — already 100 % English from the recent manual project.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — historical
  design artefacts that describe completed work; their Italian content
  documents past decisions and is intentionally preserved verbatim.
- Commit messages — historical and immutable.
- Module names, function names, atom names, variable names — already
  English throughout the codebase.

## Audience and tone

- Translations are programmer-friendly, terse, and match the existing
  English voice of the manual and the recent project README.
- Established domain terms stay as-is: `Lenie`, `codeome`, `template
  addressing`, `slot`, `nop_0` / `nop_1`. These already read as English
  technical jargon; translating them would be wrong.
- When Italian text cross-references a spec (e.g. `vedi spec §4.2`), the
  reference is preserved with English phrasing: `see spec §4.2`.

## What gets translated, concretely

### 1. Code comments and documentation

`@moduledoc`, `@doc`, inline `#` comments throughout `lib/`. Examples of
the kinds of phrases to be translated, drawn from a survey of the
codebase:

| Italian | English |
|---|---|
| "Vedi spec §4.2." | "See spec §4.2." |
| "Tolleranza alle mutazioni" | "Mutation tolerance" |
| "Costo energetico per un'esecuzione dell'opcode." | "Energy cost for one execution of the opcode." |
| "Sezione X..Y: descrizione" (in seed listings) | "Section X..Y: description" |
| "GenServer singleton che possiede le tabelle ETS" | "Singleton GenServer that owns the ETS tables" |
| "Lenie process si occupa di chiamare il World" | "The Lenie process is responsible for calling the World" |

### 2. Rendered UI strings (HEEx templates)

| Italian (current) | English (target) | File |
|---|---|---|
| `Mondo` | `World` | `dashboard_live.ex` |
| `Telemetria — popolazione totale nel tempo` | `Telemetry — total population over time` | `dashboard_live.ex` |
| `Risorse` | `Resources` | `dashboard_live.ex` |
| `Carcasse` | `Carcasses` | `dashboard_live.ex` |
| `popolaz.` | `pop.` | `dashboard_live.ex` |
| `risorse` | `resources` | `dashboard_live.ex` |
| `carcasse` | `carcasses` | `dashboard_live.ex` |
| `Una linea per ciascuna delle top N specie correnti (top 20/tick salvate in history).` | `One line per species in the current top N (top 20 per tick saved to history).` | `dashboard_live.ex` |
| `▮ Specie top N di M` | `▮ Top N species of M` | `dashboard_live.ex` |
| `Sei sicuro?` | `Are you sure?` | `controls_panel_component.ex` |
| `Sì, sterilizza` | `Yes, sterilize` | `controls_panel_component.ex` |
| `Specie:` | `Species:` | `species_live.ex` |
| `Specie con hash ... non trovata (estinta o mai esistita).` | `Species with hash ... not found (extinct or never existed).` | `species_live.ex` |
| `(Filogenia SVG-tree e diff con specie sorelle: deferito a un futuro polish.)` | `(Phylogeny SVG-tree and sister-species diff: deferred to a future polish.)` | `species_live.ex` |
| `Species — N attive` | `Species — N active` | `world_detail_component.ex` |
| `Nessun Lenie vivo` (and variants) | `No live Lenie` | `species_inspector_component.ex` |
| `Specie` (column header in HTML) | `Species` | various |

Plus any other Italian phrase found during the per-file scan that
matches the pattern. The migration uses the discoveries above as a
seed list, but each translator pass reads every comment/string and
catches anything missed by the table.

### 3. Test assertion updates

Three concrete tests reference Italian UI strings and must be updated
in lockstep:

- `test/lenies_web/live/dashboard_live_test.exs`:
  - `element("button", "Sì, sterilizza")` → `element("button", "Yes, sterilize")`
  - `assert render(view) =~ "Sei sicuro?"` → `assert render(view) =~ "Are you sure?"`
- `test/lenies_web/live/species_live_test.exs`:
  - `assert html =~ ~r/(estinto|empty|nessuno|estinta|mai esistita)/i` → `assert html =~ ~r/(extinct|not found|never existed)/i`

Any other test that breaks during a batch is fixed in the same commit.

## Execution model — five batches

| # | File group | Verification command |
|---|---|---|
| 1 | `lib/lenies/codeome/**` + `lib/lenies/codeomes/**` (~6 files) | `mix compile --warning-as-errors` |
| 2 | `lib/lenies/interpreter*` + `lib/lenies/codeome.ex` (~5 files) | `mix test test/lenies/interpreter_test.exs` |
| 3 | `lib/lenies/world*` + remaining `lib/lenies/*.ex` (mutator, telemetry, registry, lenie, lenie_supervisor, species, species_color, seeds, seeds/custom_store, snapshot, application, config, codeome_buffer) (~15 files) | `mix test test/lenies/` |
| 4 | `lib/lenies_web/**` (disassembler, grid_renderer, codeome_buffer, all live/components, controllers, layouts) + updated test files for changed UI strings (~13 files) | `mix test test/lenies_web/` |
| 5 | Final sweep: any file the previous batches missed; run `mix test` (whole suite) and `mix compile --warning-as-errors`. | `mix test` → 367 tests, 0 failures |

Each batch is one git commit. After all five, push.

## Translation conventions

- **Domain terminology preserved verbatim** — never translate `Lenie`,
  `codeome`, `template`, `slot`, `nop_0`/`nop_1`, opcode names.
- **Length kept close to original** — comments stay terse; don't add
  paragraphs. Don't reformat code structure to suit translation length.
- **No emoji added** — translations are plain text, matching the
  existing convention.
- **No tone shifts** — if the original is matter-of-fact, the
  translation is matter-of-fact. If a Carnivore moduledoc opens with
  "Variante predatoria del minimal_replicator", the translation is
  "Predatory variant of the minimal_replicator" — same register.
- **Function and variable names untouched** — they are already English.
- **Layout and whitespace preserved** — translations replace text
  in-place; don't introduce reflow that obscures the diff.

## Risk and mitigation

- **Test breakage from UI string changes** — mitigated by updating the
  three known test assertions in the same commit as the UI change
  (batch 4). The CI test step in each batch's verification catches
  anything else.
- **Loss of nuance in moduledoc** — mitigated by preserving spec
  cross-references, keeping technical terms, and matching tone.
- **Inadvertent code changes** — translation passes must touch only
  comments, docstrings, and HEEx string literals. No logic edits, no
  rename of identifiers, no reformat. Each batch's verification step
  proves logic is intact.

## Test plan

After each batch:

```bash
export PATH="$HOME/.asdf/installs/elixir/1.19.3-otp-28/bin:$HOME/.asdf/installs/erlang/28.1.1/bin:/usr/local/bin:/usr/bin:/bin"
cd /home/patrick/projects/playground/Lenies
mix compile --warning-as-errors
mix test <relevant-scope>
```

After batch 5:

```bash
mix test           # whole suite, expect 367 tests / 0 failures
```

Manual smoke test after batch 5: open `http://localhost:4001` in a
browser, confirm every visible label and button is English. Click
through Pause/Sterilize/Spawn/+ New Seed/Edit/World Detail and read
every modal title and message.

## Non-goals (YAGNI)

- No i18n / gettext infrastructure. The app becomes single-language
  English, period.
- No rewriting of moduledocs for style. Lingua-only changes.
- No retroactive translation of historical specs/plans.
- No commit-message rewriting.

## Definition of done

1. Every file in `lib/` and `test/` is free of Italian content.
2. `mix compile --warning-as-errors` succeeds.
3. `mix test` reports 367 tests, 0 failures.
4. Manual browser smoke test passes (no visible Italian text in the UI).
5. All five batch commits pushed to `origin/master`.
