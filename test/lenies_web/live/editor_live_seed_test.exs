defmodule LeniesWeb.EditorLiveSeedTest do
  use LeniesWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    :ok = Lenies.Sandboxes.attach(user.id)
    world_id = {:sandbox, user.id}
    {:ok, _handle} = Lenies.Worlds.handle(world_id)
    :ok = Lenies.Worlds.pause(world_id)

    case Process.whereis(Lenies.Manual) do
      nil -> {:ok, _} = Lenies.Manual.start_link([])
      _ -> :ok
    end

    case Process.whereis(Lenies.Snippets.Store) do
      nil -> {:ok, _} = Lenies.Snippets.Store.start_link([])
      _ -> :ok
    end

    on_exit(fn -> Lenies.Worlds.stop_world(world_id) end)
    %{world_id: world_id}
  end

  test "loads a builtin seed's opcodes into the editor", %{conn: conn} do
    seed = hd(Lenies.Seeds.all())
    chromosome = Lenies.Codeome.to_list(seed.codeome)

    plasmid_ops =
      case Map.get(seed, :plasmid) do
        nil -> []
        ops -> ops
      end

    # The listing title "Genome — N ops" reflects the whole exec genome
    # (chromosome ++ plasmids), the same geography the interpreter executes.
    n = length(chromosome) + length(plasmid_ops)

    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/seed/#{Atom.to_string(seed.id)}")

    # The listing-pane title "Genome — N ops" is the only HTML element that
    # reflects exactly the exec-genome length. The palette and the datalist
    # also contain opcode names, but neither of them changes between a loaded
    # genome and an empty one, so matching an opcode name would be a false
    # positive. An empty /sandbox/editor/new renders "Genome — 0 ops"; a
    # loaded seed renders "Genome — N ops" with N > 0.
    assert html =~ "Genome — #{n} ops"
    assert n > 0
  end

  test "editor header shows New Seed mode for seed route", %{conn: conn} do
    seed = hd(Lenies.Seeds.all())

    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/seed/#{Atom.to_string(seed.id)}")

    assert html =~ "New Seed"
  end

  test "an unknown seed id opens an empty editor without crashing", %{conn: conn} do
    assert {:ok, _view, _html} = live(conn, ~p"/sandbox/editor/seed/not_a_real_seed")
  end

  test "loads a custom (user-owned) seed's opcodes into the editor", %{conn: conn, user: user} do
    # Opcodes stored as strings, as the changeset and to_opcode_atoms/1 expect.
    opcodes = ["push1", "dup", "add"]

    {:ok, codeome} =
      Lenies.Collection.create_codeome(user, %{
        name: "test-seed-#{System.unique_integer([:positive])}",
        color_hex: "#aabbcc",
        energy_default: 500.0,
        opcodes: opcodes
      })

    {:ok, _view, html} = live(conn, ~p"/sandbox/editor/seed/custom:#{codeome.id}")

    # Same reliable signal as the builtin test: the listing-pane title
    # "Genome — 3 ops" proves the buffer was loaded, not just that opcode
    # names appear in the palette.
    assert html =~ "Genome — #{length(opcodes)} ops"
  end
end
