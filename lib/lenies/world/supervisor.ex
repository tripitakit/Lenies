defmodule Lenies.World.Supervisor do
  @moduledoc """
  Per-world supervision sub-tree (`rest_for_one`):

      Lenies.World                 GenServer (owns ETS, ticker, reconcile)
      Lenies.LenieSupervisor       per-world DynamicSupervisor for this world's Lenies
      Lenies.Telemetry             per-world telemetry collector

  Started by `Lenies.Worlds.start_world(world_id, config)` which delegates to
  `DynamicSupervisor.start_child(Lenies.Worlds.Supervisor, {__MODULE__,
  world_id: ..., config: ...})`.

  If World crashes, the ETS tables (owned by the World process) die with it;
  `rest_for_one` then restarts LenieSupervisor (killing all Lenies of this
  world) and Telemetry. The whole world resets to an empty fresh state.
  Snapshot restore is the way to recover content.

  Registered under `{:via, Registry, {Lenies.Registry, {:world_sup, world_id}}}`.

  ## Status (Task 9)

  This module is created in Task 9 but not actually used until Task 10
  switches the `:primary` world's boot from the legacy Application children
  to `Lenies.Worlds.start_world(:primary, %{})`. Until then `:primary` is
  still booted via the three flat Application children (`Lenies.World`,
  `Lenies.LenieSupervisor`, `Lenies.Telemetry`).
  """

  use Supervisor

  def start_link(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    Supervisor.start_link(__MODULE__, opts, name: via(world_id))
  end

  defp via(world_id),
    do: {:via, Registry, {Lenies.Registry, {:world_sup, world_id}}}

  @impl true
  def init(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    config = Keyword.get(opts, :config, %{})

    children = [
      {Lenies.World, world_id: world_id, config: config},
      {Lenies.LenieSupervisor, world_id: world_id},
      {Lenies.Telemetry, world_id: world_id}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
