defmodule LeniesWeb.LenieInspectorLiveTest do
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

  test "mount on /lenie/:id with a live Lenie renders state and codeome", %{conn: conn} do
    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | lenie_id: "INSP1"}})

    codeome = Codeome.from_list([:nop_0, :push1, :move])

    {:ok, pid} =
      Lenie.start_link(
        id: "INSP1",
        codeome: codeome,
        energy: 100_000.0,
        pos: {3, 3},
        dir: :e,
        lineage: {nil, 0}
      )

    Process.unlink(pid)
    Process.sleep(50)

    {:ok, _view, html} = live(conn, "/lenie/INSP1")

    assert html =~ "INSP1"
    assert html =~ ~r/Energy/i
    assert html =~ ~r/Position/i

    assert html =~ "nop_0"
    assert html =~ "push1"
    assert html =~ "move"

    GenServer.stop(pid)
  end

  test "mount on /lenie/:id with a non-existent Lenie shows a 'not found' message", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/lenie/nonexistent")
    assert html =~ ~r/(not found|deceased)/i
  end
end
