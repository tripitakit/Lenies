defmodule Lenies.WorldHandle do
  @moduledoc """
  An opaque-ish handle pointing at a single simulation world.

  Held by `Lenies.World` in its state, by Lenie processes (init arg), and by
  LiveViews that want fast-path ETS reads. Build via `Lenies.Worlds.handle/1`.
  """

  @enforce_keys [:id, :pid, :tables, :pubsub_prefix]
  defstruct [:id, :pid, :tables, :pubsub_prefix]

  @type table_key :: :cells | :lenies | :child_slots | :history | :color_overrides

  @type t :: %__MODULE__{
          id: term(),
          pid: pid(),
          tables: %{table_key() => :ets.tid()},
          pubsub_prefix: String.t()
        }
end
