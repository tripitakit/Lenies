defmodule Lenies.LenieSupervisor do
  @moduledoc """
  Per-world `DynamicSupervisor` for Lenie processes.

  Registered via `{:via, Registry, {Lenies.Registry, {:lenie_sup, world_id}}}`.
  Use `Lenies.LenieSupervisor.via(world_id)` from callers (like
  `Lenies.World.handle_call({:spawn_lenie, …}, ...)`) to get the via-tuple.

  Policy `:temporary`: a Lenie that dies (from energy exhaustion or error) is
  not restarted — death is permanent. Replication uses
  `DynamicSupervisor.start_child/2` to spawn new Lenies.
  """

  use DynamicSupervisor

  def start_link(opts) do
    world_id = Keyword.fetch!(opts, :world_id)
    DynamicSupervisor.start_link(__MODULE__, opts, name: via(world_id))
  end

  @doc """
  Via-tuple name for the LenieSupervisor of `world_id`.

  Use this from any caller that needs to address a per-world LenieSupervisor:

      DynamicSupervisor.start_child(Lenies.LenieSupervisor.via(world_id), spec)
  """
  def via(world_id),
    do: {:via, Registry, {Lenies.Registry, {:lenie_sup, world_id}}}

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
