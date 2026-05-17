defmodule Lenies.Registry do
  @moduledoc """
  `Registry` wrapper that maps Lenie id ↔ pid.

  Used by `Lenies.Lenie` to identify itself at runtime (e.g. `Registry.whereis(id)`
  to send messages without holding a pid). Registered in the supervision tree as
  `Lenies.Registry`.

  See spec §3.1.
  """

  @name __MODULE__

  @doc "Child spec for the supervision tree."
  def child_spec(_init_arg) do
    Elixir.Registry.child_spec(keys: :unique, name: @name)
  end

  @doc "Register the calling process under `id`. The binding is released when the process dies."
  def register(id) do
    Elixir.Registry.register(@name, id, nil)
  end

  @doc "Returns the pid associated with `id`, or `nil` if not registered."
  def whereis(id) do
    case Elixir.Registry.lookup(@name, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Number of currently registered processes."
  def count, do: Elixir.Registry.count(@name)
end
