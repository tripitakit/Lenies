defmodule Lenies.LeniePubsubTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, Lenie}

  setup do
    {:ok, world_id} = Lenies.WorldTestHelpers.start_test_world(tick_interval_ms: 0)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    on_exit(fn -> Lenies.WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, world_id: world_id, handle: handle}
  end

  test "Lenie broadcasts {:lenie_update, snap} on its per-id topic",
       %{world_id: world_id, handle: handle} do
    [{key, cell}] = :ets.lookup(Lenies.WorldTestHelpers.cells(world_id), {3, 3})
    :ets.insert(Lenies.WorldTestHelpers.cells(world_id), {key, %{cell | lenie_id: "PUB1"}})

    Phoenix.PubSub.subscribe(Lenies.PubSub, handle.pubsub_prefix <> ":lenie:PUB1")

    codeome = Codeome.from_list([:nop_0, :nop_0])

    {:ok, pid} =
      Lenie.start_link(
        {handle,
         [
           id: "PUB1",
           codeome: codeome,
           energy: 1000.0,
           pos: {3, 3},
           dir: :n,
           lineage: {nil, 0}
         ]}
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
