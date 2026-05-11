defmodule LeniesWeb.SpeciesLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lenies.{Codeome, Lenie, World}
  alias Lenies.World.Tables

  setup do
    case Process.whereis(Lenies.World) do
      nil ->
        {:ok, _} = World.start_link(tick_interval_ms: 0)

      _ ->
        :ok
    end

    on_exit(fn ->
      case Process.whereis(Lenies.World) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      Tables.delete_all()
    end)

    :ok
  end

  test "mount on /species/:hash with a known species shows lineage", %{conn: conn} do
    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | lenie_id: "SP1"}})

    codeome = Codeome.from_list([:nop_0, :push1])
    hash = Codeome.hash(codeome)

    {:ok, pid} =
      Lenie.start_link(
        id: "SP1",
        codeome: codeome,
        energy: 100_000.0,
        pos: {3, 3},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    Process.sleep(50)

    {:ok, _view, html} = live(conn, "/species/#{hash}")

    assert html =~ hash
    assert html =~ ~r/Popolazione/i
    # lineage entry
    assert html =~ "SP1"

    GenServer.stop(pid)
  end

  test "mount on /species/:hash with unknown hash shows empty/extinct", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/species/00000000")
    assert html =~ ~r/(estinto|empty|nessuno|estinta|mai esistita)/i
  end
end
