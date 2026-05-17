defmodule Lenies.LenieSupervisor do
  @moduledoc """
  DynamicSupervisor that hosts all Lenie processes.

  Policy `:temporary`: a Lenie that dies (from energy exhaustion or error) is
  not restarted — death is permanent. Replication uses
  `DynamicSupervisor.start_child/2` to spawn new Lenies.
  """

  use DynamicSupervisor

  @name __MODULE__

  def start_link(_init_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: @name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
