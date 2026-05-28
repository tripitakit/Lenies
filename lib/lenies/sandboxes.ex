defmodule Lenies.Sandboxes do
  @moduledoc """
  Per-user sandbox lifecycle manager.

  Each logged-in user has exactly one sandbox — a `Lenies.Worlds`
  instance keyed `{:sandbox, user.id}` — that lives only while the user
  is connected. The first LiveView mount attaches; subsequent mounts
  (multi-tab, editor + dashboard) share the same world. The last
  disconnect schedules a grace-period timer; if no re-attach happens
  within that window, the world auto-snapshots to disk and stops. The
  next connection auto-restores from that snapshot.

  See `docs/superpowers/specs/2026-05-28-personal-sandbox-design.md`.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the world id for a user id. Pure helper."
  @spec world_id_for(integer) :: {:sandbox, integer}
  def world_id_for(user_id) when is_integer(user_id), do: {:sandbox, user_id}

  @impl true
  def init(_opts), do: {:ok, %{}}
end
