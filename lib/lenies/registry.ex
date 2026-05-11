defmodule Lenies.Registry do
  @moduledoc """
  Wrapper di `Registry` per associare id Lenie ↔ pid.

  Usato da `Lenies.Lenie` per identificarsi a runtime (es. `Registry.whereis(id)`
  per inviare messaggi senza tenere pid in giro). Registrato nell'albero di
  supervisione come `Lenies.Registry`.

  Vedi spec §3.1.
  """

  @name __MODULE__

  @doc "Child spec per la supervision tree."
  def child_spec(_init_arg) do
    Elixir.Registry.child_spec(keys: :unique, name: @name)
  end

  @doc "Registra il processo chiamante con `id`. Il binding cessa quando il processo muore."
  def register(id) do
    Elixir.Registry.register(@name, id, nil)
  end

  @doc "Ritorna il pid associato a `id`, o `nil` se non registrato."
  def whereis(id) do
    case Elixir.Registry.lookup(@name, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Numero di processi attualmente registrati."
  def count, do: Elixir.Registry.count(@name)
end
