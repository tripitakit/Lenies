defmodule Lenies.Worlds.Supervisor do
  @moduledoc """
  DynamicSupervisor of per-world supervision sub-trees. Started once per node
  by `Lenies.Application`. `Lenies.Worlds.start_world/2` calls
  `DynamicSupervisor.start_child(__MODULE__, ...)` to spin up a world.

  The child spec is `Lenies.World.Supervisor` (a per-world `Supervisor`
  module). No worlds are booted at application startup — per-user sandbox
  worlds are spawned on demand via `Lenies.Sandboxes`, and ad-hoc worlds
  in tests are spawned via `Lenies.WorldTestHelpers.start_test_world/1`.
  """
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
