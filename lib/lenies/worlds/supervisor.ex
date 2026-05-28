defmodule Lenies.Worlds.Supervisor do
  @moduledoc """
  DynamicSupervisor of per-world supervision sub-trees. Started once per node
  by `Lenies.Application`. `Lenies.Worlds.start_world/2` calls
  `DynamicSupervisor.start_child(__MODULE__, ...)` to spin up a world.

  The child spec is `Lenies.World.Supervisor` (a per-world `Supervisor`
  module — to be added in Task 9). For now this DynamicSupervisor exists
  but no worlds are started through it; the existing `:primary` world is
  still booted via the legacy `Lenies.World` child in `Lenies.Application`
  (migrated in Task 10).
  """
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
