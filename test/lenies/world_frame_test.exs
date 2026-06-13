defmodule Lenies.WorldFrameTest do
  use ExUnit.Case, async: false

  alias Lenies.{Codeome, WorldFrame, WorldTestHelpers}

  setup do
    {:ok, world_id} = WorldTestHelpers.start_test_world()
    on_exit(fn -> WorldTestHelpers.stop_test_world(world_id) end)
    {:ok, handle} = Lenies.Worlds.handle(world_id)
    {:ok, world_id: world_id, handle: handle}
  end

  defp byte_at(b64, x, y, w), do: :binary.at(Base.decode64!(b64), y * w + x)

  test "energy + meta encode per-cell traits", %{world_id: world_id, handle: handle} do
    # Herbivore (no :attack), facing north (default), energy 1000 (== ref).
    cod = Codeome.from_list([:eat, :move, :nop_0, :nop_0, :nop_0])
    {:ok, {_id, {x, y}}} = Lenies.Worlds.spawn_lenie(world_id, cod, energy: 1000.0)

    {w, h} = Lenies.Config.grid_size()
    p = WorldFrame.encode_payload(handle, {w, h})

    # Energy: 1000 / energy_ref(1000) * 255 ≈ 255 (full).
    assert byte_at(p.energy, x, y, w) >= 250
    # Meta: dir bits = 0 (:n), predator bit (4) clear, plasmid bit (8) clear.
    meta = byte_at(p.meta, x, y, w)
    assert Bitwise.band(meta, 0x03) == 0
    assert Bitwise.band(meta, 0x04) == 0
    assert Bitwise.band(meta, 0x08) == 0
  end

  test "predator bit set when codeome contains :attack", %{world_id: world_id, handle: handle} do
    cod = Codeome.from_list([:attack, :move, :nop_0, :nop_0, :nop_0])
    {:ok, {_id, {x, y}}} = Lenies.Worlds.spawn_lenie(world_id, cod, energy: 500.0)
    {w, h} = Lenies.Config.grid_size()
    p = WorldFrame.encode_payload(handle, {w, h})
    assert Bitwise.band(byte_at(p.meta, x, y, w), 0x04) == 0x04
  end

  test "empty cell encodes 0 in energy and meta", %{handle: handle} do
    {w, h} = Lenies.Config.grid_size()
    p = WorldFrame.encode_payload(handle, {w, h})
    # (0,0) is empty in a fresh world.
    assert byte_at(p.energy, 0, 0, w) == 0
    assert byte_at(p.meta, 0, 0, w) == 0
  end
end
