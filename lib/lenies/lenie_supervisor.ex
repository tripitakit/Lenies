defmodule Lenies.LenieSupervisor do
  @moduledoc """
  Per-world `DynamicSupervisor` for Lenie processes.

  Registered via `{:via, Registry, {Lenies.Registry, {:lenie_sup, world_id}}}`.
  Use `Lenies.LenieSupervisor.via(world_id)` from callers (like
  `Lenies.World.handle_call({:spawn_lenie, …}, ...)`) to get the via-tuple.

  Policy `:temporary`: a Lenie that dies (from energy exhaustion or error) is
  not restarted — death is permanent. Replication uses
  `DynamicSupervisor.start_child/2` to spawn new Lenies.

  ## Compat shim (removed in Task 10)

  The `:primary` world's LenieSupervisor is ALSO registered under the global
  atom name `Lenies.LenieSupervisor` so legacy callers can keep using
  `DynamicSupervisor.start_child(Lenies.LenieSupervisor, …)` and
  `Process.whereis(Lenies.LenieSupervisor)` during the transition. All other
  worlds register only under the via-Registry tuple.
  """

  use DynamicSupervisor

  def start_link(opts) do
    world_id = Keyword.fetch!(opts, :world_id)

    case DynamicSupervisor.start_link(__MODULE__, opts, name: via(world_id)) do
      {:ok, pid} = ok ->
        # Compat shim (removed in Task 10): the `:primary` world's
        # LenieSupervisor is ALSO registered under the global atom name
        # `Lenies.LenieSupervisor` so legacy callers
        # (`Process.whereis(Lenies.LenieSupervisor)`,
        # `DynamicSupervisor.start_child(Lenies.LenieSupervisor, …)`) keep
        # working during the transition.
        if world_id == :primary do
          try do
            Process.register(pid, __MODULE__)
          rescue
            ArgumentError -> :ok
          end
        end

        ok

      other ->
        other
    end
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
