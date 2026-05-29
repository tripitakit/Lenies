defmodule LeniesWeb.SpeciesLiveTest do
  use LeniesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lenies.{Codeome, Lenie}

  setup :register_and_log_in_user

  setup %{user: user} do
    # Attach the test pid to the user's sandbox so its ETS tables / Registry
    # are available BEFORE the LV mounts. Pause to keep the world quiescent.
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    :ok = Lenies.Worlds.pause(world_id)

    on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)

    %{world_id: world_id, handle: handle}
  end

  test "mount on /sandbox/species/:hash with a known species shows lineage",
       %{conn: conn, handle: handle} do
    [{key, cell}] = :ets.lookup(handle.tables.cells, {3, 3})
    :ets.insert(handle.tables.cells, {key, %{cell | lenie_id: "SP1"}})

    codeome = Codeome.from_list([:nop_0, :push1])
    hash = Codeome.hash(codeome)

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "SP1",
           codeome: codeome,
           energy: 100_000.0,
           pos: {3, 3},
           dir: :n,
           lineage: {nil, 0}
         ]}
      )

    Process.unlink(pid)
    Process.sleep(50)

    {:ok, _view, html} = live(conn, ~p"/sandbox/species/#{hash}")

    assert html =~ hash
    assert html =~ ~r/Population/i
    # lineage entry
    assert html =~ "SP1"

    GenServer.stop(pid)
  end

  test "mount on /sandbox/species/:hash with unknown hash shows empty/extinct", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sandbox/species/00000000")
    assert html =~ ~r/(extinct|not found|never existed|empty)/i
  end

  test "flash group is rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandbox/species/00000000")
    assert has_element?(view, "#flash-group")
    assert has_element?(view, "#client-error")
    assert has_element?(view, "#server-error")
  end
end
