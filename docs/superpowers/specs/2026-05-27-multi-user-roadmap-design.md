# Multi-user Lenies — roadmap & north-star design

**Date:** 2026-05-27
**Status:** High-level roadmap approved; per-sub-project specs to follow
**Scope:** Turn the single-world, single-user Lenies sandbox into a multi-user
application with per-user private sandboxes and one shared realtime Arena.

This document is a **roadmap, not an implementation spec.** It records the
decisions taken during brainstorming and decomposes the work into four
sub-projects, each of which gets its own design spec → plan → implementation
cycle. Architectural choices internal to a sub-project (e.g. how multi-world ETS
isolation is implemented) are deliberately deferred to that sub-project's own
brainstorming.

## Goal

Three user-facing capabilities, on top of today's simulation engine:

1. **Accounts** — users register, log in, and own private data.
2. **Personal sandbox** — each user gets an isolated world to test and iterate on
   the codeomes they write, before committing them to the shared world.
3. **Shared Arena** — one global, persistent, realtime multi-user world where
   users *seed* a Lenie from their personal collection and watch the shared
   ecosystem evolve.

## Where we start from (today's architecture)

- **Single-world singleton.** `Lenies.World` is a globally-named GenServer; one
  world per app instance.
- **ETS with global atom table names** — `:cells`, `:lenies`, `:child_slots`,
  `:history`, `:species_codeomes`, `:species_color_overrides`. Two worlds in one
  node would collide.
- **Global PubSub topics** — `"world:tick"`, `"world:control"`, `"world:fx"`,
  `"lenie:<id>"`, all unscoped.
- **No identity, no database.** No Ecto/Postgres, no accounts, no auth. User
  seeds live in a single global JSON file (`priv/user_seeds.json` via
  `Lenies.Seeds.CustomStore`).
- **Snapshots** via `:ets.tab2file/2` to a single global root directory.

Key insight: **today's app is already nearly an Arena** — a global, shared,
persistent world. What is missing is (a) identity, (b) the ability to run
*several* isolated worlds in one node, and (c) two distinct lifecycles. So we do
not rewrite: we extract a **parameterized simulation engine** and run it in two
modes (ephemeral sandbox, persistent Arena).

## Locked decisions

| Area | Decision |
|------|----------|
| Deployment scale | Small public community: open registration, tens–hundreds of users, **single BEAM node**, Postgres. |
| Auth | **phx.gen.auth** (email/password, email confirmation, password reset). No external deps. |
| Sandbox lifecycle | **Runs only while the user is connected.** Started on open, snapshotted to durable storage on disconnect / inactivity timeout, stopped. No offline/background evolution. |
| Arena topology | **One single global Arena**, persistent. Runs while ≥1 viewer is connected; pauses + snapshots when empty. |
| Personal collection | **Hand-written codeomes only.** A collection entry ≈ today's seed (opcodes + colour + default starting energy) but owner-scoped. No capture-from-simulation, no evolved-state serialization. "Training" = iterate in the editor and test in the sandbox. |
| Built-in seeds | Remain a shared, read-only library available to everyone. |
| Transition | The current single-world dashboard **may be retired** once Arena + Sandbox exist. No requirement to keep it accessible during the transition. |
| Arena control surface | **Read-mostly.** Users get: view map/layers, sparkline + species table, species inspector, presence ("who's watching"), and **seed a Lenie from their collection**. Tuning, Pause, Sterilize, Snapshot/Restore are **not exposed** to regular users (admin-only, out of current scope). |
| Sandbox control surface | **Full.** It is the user's private lab: tuning sliders, pause, sterilize, spawn-from-collection, and snapshot all available. |

## Decomposition (4 sub-projects, bottom-up)

### 1 — Foundations: Identity & persistence
- Add Ecto + Postgres; run `phx.gen.auth` to create `users`, sessions,
  registration/login/confirmation/reset.
- Migrate the personal collection from the global `priv/user_seeds.json` to a
  `codeomes` table scoped by `owner_id` (opcodes, name, colour, default energy).
  Built-in seeds stay a shared read-only library.
- **Deliverable:** register/login works; saved codeomes are private per user;
  the existing dashboard still runs.
- **Risk:** low. Standard Phoenix territory.

### 2 — Multi-world engine
- Parameterize `World` and the simulation to run as N isolated instances in one
  node: per-world ETS storage (no global atom collisions), a Registry keyed by
  `world_id`, a `WorldsSupervisor` (DynamicSupervisor), and per-world PubSub
  topics (`"world:#{id}:tick"`, etc.).
- No user-facing change — this is a refactor proven by tests that two worlds run
  independently in one node.
- **Deliverable:** `Worlds.start(id, config)` / `Worlds.stop(id)`; two live
  worlds with no cross-talk.
- **Risk:** highest. This is the core refactor. The internal isolation strategy
  (prefixed named tables vs. unnamed tables-by-reference) is decided in this
  sub-project's own brainstorming.

### 3 — Personal sandbox
- One world instance per active user with the "alive while connected, snapshot on
  disconnect/timeout, then stop" lifecycle. Sandbox dashboard scoped to the user;
  spawn from the personal collection; full control surface.
- Reuses the engine from #2 and the durable per-user snapshot storage.
- **Risk:** medium (lifecycle/liveness edges: reconnects, multiple tabs, timeout).

### 4 — Global Arena
- Re-home the existing world as the single scoped Arena: runs while ≥1 viewer,
  pauses + snapshots when empty, `Phoenix.Presence` for "who's watching",
  seed-from-collection, read-mostly control surface.
- Builds on #2 and reuses the lifecycle patterns from #3.
- **Risk:** medium (shared-state concurrency, presence, anti-grief on seeding).

## Sequencing

**1 → 2 → 3 → 4.** #1 and #2 are partly parallelizable, but #1 is low-risk and
fixes the data model; #2 is the big refactor. #3 needs #1 + #2. #4 needs #2 and
reuses #3's lifecycle code. Each sub-project gets its own spec → plan →
implementation cycle.

## Open questions (deferred to the relevant sub-project)

- **#2:** ETS isolation strategy — prefixed named tables vs. unnamed
  tables-by-reference threaded through world state. (To be brainstormed in #2.)
- **#3/#4:** durable snapshot storage target — disk keyed by user/arena vs.
  Postgres blob. (Single node, so disk is viable; decided per sub-project.)
- **#3:** sandbox quotas / inactivity-timeout value to bound concurrent worlds.
- **#4:** anti-grief on Arena seeding (rate limit, cap per user, energy budget).
- **Admin role** for Arena tuning/pause/sterilize — explicitly out of current
  scope.
