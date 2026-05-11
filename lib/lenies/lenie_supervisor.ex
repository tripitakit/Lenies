defmodule Lenies.LenieSupervisor do
  @moduledoc """
  DynamicSupervisor che ospita tutti i processi Lenie.

  Policy `:temporary`: un Lenie che muore (per esaurimento energia o errore)
  non viene riavviato — è una morte definitiva. La replicazione (sotto-progetto 3)
  userà `DynamicSupervisor.start_child/2` per spawnare nuovi Lenies.

  Vuoto in questo sotto-progetto; pronto per essere popolato dal sotto-progetto 3.
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
