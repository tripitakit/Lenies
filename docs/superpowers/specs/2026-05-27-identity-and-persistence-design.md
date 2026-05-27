# Sub-project #1 — Identity & persistence

**Date:** 2026-05-27
**Status:** Design approved, pending spec review
**Part of:** `2026-05-27-multi-user-roadmap-design.md` (sub-project #1 of 4)

## Goal

Lay the foundations the rest of the multi-user roadmap stands on: user accounts
and a database, and move the personal codeome collection from a single global
JSON file to per-user database storage. No change to the simulation engine.

**Deliverable:** a user can register, log in, and save codeomes that are private
to their account; the existing dashboard/editor still work, now behind login.

## Starting point

- Phoenix 1.8.1, LiveView 1.1.0. **No Ecto/Postgres, no auth** in the project.
- The personal collection lives in `Lenies.Seeds.CustomStore`: an `Agent`
  backed by `priv/user_seeds.json`. A collection entry is
  `%{id, name, color_hex, energy_default, opcodes}` where `opcodes` is a list of
  whitelisted opcode atoms, length-capped by `Config.codeome_length_bounds/0`.
- The editor (`LeniesWeb.EditorLive`) and the dashboard spawn dropdown read,
  save, and delete entries through `CustomStore`. Built-in seeds come from
  `Lenies.Seeds`.

## Decisions (locked in brainstorming)

| Question | Decision |
|----------|----------|
| Framework | **Stay vanilla**: Ecto + `phx.gen.auth` + contexts. Ash Framework was evaluated and consciously declined at this stage — the project's center of gravity is the simulation engine / multi-world OTP refactor, which Ash does not touch; the persistence slice it would own is small and well-served by standard tools. Revisit only if a public API or rich policies become a driver. |
| Auth | `phx.gen.auth` (Phoenix 1.8 **scope-based**): `Scope` struct + `current_scope` assign. |
| Auth boundary | **Whole app behind login** for this sub-project. Anonymous viewing is deferred to the Arena (#4). |
| Existing `user_seeds.json` data | **Discard** — start clean. No one-time import code. The `codeomes` table starts empty. The JSON file is no longer read or written. |
| `opcodes` column | **`{:array, :string}`** (e.g. `["nop_0","eat","move"]`): mirrors today's JSON format, readable in the DB, converted to atoms via `String.to_existing_atom/1` (same safety as today). |
| Built-in seeds | Remain a shared, read-only library from `Lenies.Seeds`. |

## Design

### 1. Dependencies & database

- Add deps: `ecto_sql`, `postgrex`, `phoenix_ecto`.
- Create `Lenies.Repo`; add it to the supervision tree.
- Config: dev / test / prod Postgres connection (test uses the Ecto SQL Sandbox).
- Aliases (`mix.exs`): `setup` gains `ecto.setup`; add `ecto.reset`. `precommit`
  already runs `test` — tests now require the test DB to exist/migrate.
- Nothing here touches the simulation engine; the world stays in ETS.

### 2. Auth via phx.gen.auth (scope-based)

- Run `mix phx.gen.auth Accounts User users`, producing the `Accounts` context,
  `User` + `UserToken` schemas, registration / login / email-confirmation /
  password-reset flows, and the `Scope` system with `current_scope` in LiveView
  assigns and conn.
- Router: a single authenticated pipeline guards the whole app via
  `require_authenticated_user` (the generated `live_session` + `on_mount` hook).
  Only the auth routes themselves are public.
- `current_scope.user` is the actor used to scope all collection queries.

### 3. `Collection` context + `Codeome` schema

New context `Lenies.Collection` with schema `Lenies.Collection.Codeome` mapped to
table `codeomes`:

| column | type | constraints |
|--------|------|-------------|
| `id` | bigserial | PK |
| `owner_id` | FK → `users.id` | `null: false`, `on_delete: :delete_all`, indexed |
| `name` | `:string` | non-empty after trim; must contain `[a-zA-Z0-9]` |
| `color_hex` | `:string` | matches `^#[0-9a-fA-F]{6}$` |
| `energy_default` | `:float` | default `10000.0`; must be a number |
| `opcodes` | `{:array, :string}` | non-empty; every element in `Codeome.Opcodes.all/0`; length ≤ `elem(Config.codeome_length_bounds/0, 1)` |
| `inserted_at` / `updated_at` | timestamps | |

- The changeset ports the **exact validations** currently in `CustomStore`
  (name, color, opcodes whitelist + length cap). The opcode-length cap is read
  at validation time so it tracks runtime config.
- Context API (all take the owner / `Scope` and scope every query by `owner_id`):
  `list_codeomes(scope)`, `get_codeome(scope, id)`, `create_codeome(scope, attrs)`,
  `update_codeome(scope, codeome, attrs)`, `delete_codeome(scope, codeome)`,
  `change_codeome/2`. A user can only read/update/delete their own rows.
- Loading for the simulation: opcode strings → atoms via
  `String.to_existing_atom/1`, after the same length guard `CustomStore` applies,
  so a malformed/oversized row can never reach the interpreter. (The DB changeset
  already prevents writing invalid rows; the guard protects the read path
  defensively.)

### 4. Wiring & removal of the old store

- Replace every `CustomStore.{all,get,save,delete}` call site (editor save/load,
  dashboard spawn dropdown) with `Collection` functions scoped to
  `current_scope`.
- The spawn dropdown shows built-in seeds (shared) + the current user's codeomes.
- **Remove** `Lenies.Seeds.CustomStore`, its `Agent` child from the supervision
  tree, and all reads/writes of `priv/user_seeds.json`. The file may remain on
  disk untouched but is no longer referenced.

### 5. Testing

- Add `Lenies.DataCase` and configure the Ecto SQL Sandbox; LiveView/conn tests
  get an authenticated user via the generated test helpers.
- Replace `CustomStore`'s test suite with `Collection` tests: changeset
  validations (name, color, opcodes whitelist, length cap, energy) and
  owner-scoping (user A cannot see/modify user B's codeomes).
- `phx.gen.auth` brings its own auth tests.
- Dev-env note: run the suite with `MIX_ENV=test` to avoid the dev build lock;
  the test DB must be created/migrated first.

## Out of scope (later sub-projects)

- Multi-world engine / scoping ETS, PubSub, Registry — **#2**.
- Per-user sandbox lifecycle and durable snapshot storage — **#3**.
- Arena, presence, anonymous viewing, seed-from-collection in a shared world — **#4**.
- Admin role for tuning/pause/sterilize.

## Risks & notes

- **Low risk overall** — standard Phoenix territory.
- Introducing Postgres changes the test story (DB must exist; sandbox setup).
  The existing `precommit` alias runs the suite, so CI/local precommit now needs
  a reachable test database.
- `phx.gen.auth` generates many files (templates, mailer, tokens); review the
  generated router/layout integration so it composes with the existing
  dark sci-fi dashboard layout rather than fighting it.
