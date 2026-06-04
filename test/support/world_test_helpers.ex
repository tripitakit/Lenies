defmodule Lenies.WorldTestHelpers do
  @moduledoc """
  Test-only helpers for spinning up isolated worlds without going through
  `Lenies.Sandboxes`. Use `start_test_world/1` for tests that don't care
  about user-scoping; use `Lenies.Sandboxes.attach(user.id)` directly for
  tests that exercise the per-user sandbox lifecycle.

  All accessors take a `world_id` so the same helper can serve any test
  world. Tests that need the unnamed ETS tids directly should reach into
  the `%Lenies.WorldHandle{}` returned by `Lenies.Worlds.handle/1`.
  """

  @config_keys [
    :tick_interval_ms,
    :eat_amount,
    :radiation_per_tick,
    :carcass_decay,
    :lenie_metabolize_delay_ms,
    :copy_substitution_rate,
    :copy_insert_rate,
    :copy_delete_rate,
    :background_mutation_rate_per_1000_ticks,
    :attack_damage
  ]

  @doc """
  Starts an isolated world under `Lenies.Worlds.Supervisor` and returns
  `{:ok, world_id}`. Caller is responsible for `stop_test_world(world_id)`
  (typically in `on_exit/1`).

  ## Options
  - `:as` — explicit world id (atom or `{atom, term}` tuple). Defaults to a
    per-test atom derived from the calling pid.
  - Any of the per-world `%Lenies.World.Config{}` keys (e.g.
    `:tick_interval_ms`, `:eat_amount`, ...) — passed as config overrides.

  Idempotent: if the chosen world id is already running, returns its id.

  Accepts either a keyword list or a map of config overrides; both
  `start_test_world(%{tick_interval_ms: 0})` and
  `start_test_world(tick_interval_ms: 0)` are equivalent.
  """
  def start_test_world(opts \\ [])

  def start_test_world(opts) when is_map(opts) do
    start_test_world(Enum.into(opts, []))
  end

  def start_test_world(opts) when is_list(opts) do
    world_id = Keyword.get_lazy(opts, :as, &generate_test_world_id/0)

    config =
      opts
      |> Keyword.take(@config_keys)
      |> Map.new()

    case Lenies.Worlds.start_world(world_id, config) do
      {:ok, _sup} -> {:ok, world_id}
      {:error, {:already_started, _}} -> {:ok, world_id}
      other -> other
    end
  end

  @doc """
  Stop the world started by `start_test_world/1` (and its full sub-tree:
  World + LenieSupervisor + Telemetry). Also clears the per-world
  named-table fixtures registered on this node. Idempotent.
  """
  def stop_test_world(world_id) do
    Lenies.Worlds.stop_world(world_id)
    Lenies.World.Tables.delete_all()
    :ok
  end

  @doc "ETS tid for the given world's `:cells` table."
  def cells(world_id), do: handle!(world_id).tables.cells

  @doc "ETS tid for the given world's `:lenies` table."
  def lenies(world_id), do: handle!(world_id).tables.lenies

  @doc "ETS tid for the given world's `:child_slots` table."
  def child_slots(world_id), do: handle!(world_id).tables.child_slots

  @doc "ETS tid for the given world's `:history` table."
  def history(world_id), do: handle!(world_id).tables.history

  @doc "Pid of the running World GenServer for `world_id`, or nil if not running."
  def world_pid(world_id) do
    case Registry.lookup(Lenies.Registry, {:world, world_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Pid of the running LenieSupervisor for `world_id`, or nil if not running."
  def lenie_sup_pid(world_id) do
    case Registry.lookup(Lenies.Registry, {:lenie_sup, world_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Pid of the running Telemetry for `world_id`, or nil if not running."
  def telemetry_pid(world_id) do
    case Registry.lookup(Lenies.Registry, {:telemetry, world_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Internal: fetch the world's handle, raising if the world isn't running.
  defp handle!(world_id) do
    case Lenies.Worlds.handle(world_id) do
      {:ok, h} -> h
      :error -> raise "Lenies.WorldTestHelpers: world #{inspect(world_id)} is not running"
    end
  end

  # Per-test pid → bounded atom growth (pids are reused across runs, so the
  # atom table doesn't grow unboundedly across a long test run).
  defp generate_test_world_id do
    String.to_atom("test_world_" <> inspect(self()))
  end
end
