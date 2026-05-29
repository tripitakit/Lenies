defmodule LeniesWeb.LenieInspectorLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lenies.{Codeome, Lenie}

  setup :register_and_log_in_user

  setup %{user: user} do
    # Attach the test pid to the user's sandbox so its ETS tables / Registry
    # are available BEFORE the LV mounts. Pause to keep the world quiescent
    # so pre-inserted Lenie data isn't perturbed by ticks.
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    :ok = Lenies.Worlds.pause(world_id)

    on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)

    %{world_id: world_id, handle: handle}
  end

  test "mount on /sandbox/lenie/:id with a live Lenie renders state and codeome",
       %{conn: conn, handle: handle} do
    [{key, cell}] = :ets.lookup(handle.tables.cells, {3, 3})
    :ets.insert(handle.tables.cells, {key, %{cell | lenie_id: "INSP1"}})

    codeome = Codeome.from_list([:nop_0, :push1, :move])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "INSP1",
           codeome: codeome,
           energy: 100_000.0,
           pos: {3, 3},
           dir: :e,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)
    Process.sleep(50)

    {:ok, _view, html} = live(conn, ~p"/sandbox/lenie/INSP1")

    assert html =~ "INSP1"
    assert html =~ ~r/Energy/i
    assert html =~ ~r/Position/i

    assert html =~ "nop_0"
    assert html =~ "push1"
    assert html =~ "move"

    GenServer.stop(pid)
  end

  test "mount on /sandbox/lenie/:id with a non-existent Lenie shows a 'not found' message", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/sandbox/lenie/nonexistent")
    assert html =~ ~r/(not found|deceased)/i
  end

  test "flash group is rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/lenie/nonexistent")
    assert has_element?(view, "#flash-group")
    assert has_element?(view, "#client-error")
    assert has_element?(view, "#server-error")
  end
end
