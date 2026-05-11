defmodule Lenies.LeniePubsubTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie, World}
  alias Lenies.World.Tables

  setup do
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

    {:ok, _world} = World.start_link(tick_interval_ms: 0)
    :ok
  end

  test "Lenie broadcasts {:lenie_update, snap} on its per-id topic" do
    [{key, cell}] = :ets.lookup(:cells, {3, 3})
    :ets.insert(:cells, {key, %{cell | lenie_id: "PUB1"}})

    Phoenix.PubSub.subscribe(Lenies.PubSub, "lenie:PUB1")

    codeome = Codeome.from_list([:nop_0, :nop_0])

    {:ok, pid} =
      Lenie.start_link(
        id: "PUB1",
        codeome: codeome,
        energy: 1000.0,
        pos: {3, 3},
        dir: :n,
        lineage: {nil, 0}
      )

    Process.unlink(pid)

    # The initial snapshot is written in init/1; assert we receive it
    assert_receive {:lenie_update, snap}, 500
    assert snap.id == "PUB1"

    # Should also broadcast periodically as batches run
    assert_receive {:lenie_update, _}, 500

    GenServer.stop(pid)
  end
end
