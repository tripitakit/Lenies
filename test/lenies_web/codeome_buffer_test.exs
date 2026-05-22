defmodule LeniesWeb.CodeomeBufferTest do
  use ExUnit.Case, async: false

  alias LeniesWeb.CodeomeBuffer

  describe "insert/3" do
    test "inserts at the given index, shifting later items right" do
      assert CodeomeBuffer.insert([:a, :b, :c], 1, :z) == [:a, :z, :b, :c]
    end

    test "inserts at the start with index 0" do
      assert CodeomeBuffer.insert([:a, :b], 0, :z) == [:z, :a, :b]
    end

    test "inserts at the end when index >= length" do
      assert CodeomeBuffer.insert([:a, :b], 99, :z) == [:a, :b, :z]
    end

    test "inserts into an empty buffer" do
      assert CodeomeBuffer.insert([], 0, :z) == [:z]
    end
  end

  describe "delete/2" do
    test "removes the item at the index" do
      assert CodeomeBuffer.delete([:a, :b, :c], 1) == [:a, :c]
    end

    test "removes the first item" do
      assert CodeomeBuffer.delete([:a, :b], 0) == [:b]
    end

    test "is a no-op when index is past the end" do
      assert CodeomeBuffer.delete([:a, :b], 99) == [:a, :b]
    end

    test "is a no-op on an empty buffer" do
      assert CodeomeBuffer.delete([], 0) == []
    end
  end

  describe "replace/3" do
    test "replaces the item at the index" do
      assert CodeomeBuffer.replace([:a, :b, :c], 1, :z) == [:a, :z, :c]
    end

    test "is a no-op past the end" do
      assert CodeomeBuffer.replace([:a, :b], 99, :z) == [:a, :b]
    end

    test "is a no-op on an empty buffer" do
      assert CodeomeBuffer.replace([], 0, :z) == []
    end
  end

  describe "move/3" do
    test "moves later" do
      assert CodeomeBuffer.move([:a, :b, :c, :d], 0, 2) == [:b, :c, :a, :d]
    end

    test "moves earlier" do
      assert CodeomeBuffer.move([:a, :b, :c, :d], 3, 1) == [:a, :d, :b, :c]
    end

    test "is a no-op when from == to" do
      assert CodeomeBuffer.move([:a, :b, :c], 1, 1) == [:a, :b, :c]
    end

    test "is a no-op when from is out of range" do
      assert CodeomeBuffer.move([:a, :b], 99, 0) == [:a, :b]
    end

    test "clamps to to length when too large" do
      assert CodeomeBuffer.move([:a, :b, :c], 0, 99) == [:b, :c, :a]
    end
  end

  describe "validate/1" do
    setup do
      original_bounds = Application.get_env(:lenies, :codeome_length_bounds)
      original_min_non_nops = Application.get_env(:lenies, :min_viable_codeome_opcodes)

      Application.put_env(:lenies, :codeome_length_bounds, {5, 500})
      Application.put_env(:lenies, :min_viable_codeome_opcodes, 10)

      on_exit(fn ->
        if original_bounds do
          Application.put_env(:lenies, :codeome_length_bounds, original_bounds)
        end

        if original_min_non_nops do
          Application.put_env(:lenies, :min_viable_codeome_opcodes, original_min_non_nops)
        end
      end)

      :ok
    end

    test "ok when length and non_nops both satisfied" do
      buffer = List.duplicate(:nop_0, 5) ++ List.duplicate(:push0, 10)
      assert {:ok, %{len: 15, non_nops: 10}} = CodeomeBuffer.validate(buffer)
    end

    test "errors when too short" do
      assert {:error, errs} = CodeomeBuffer.validate([:push0, :push0])
      assert {:too_short, min: 5, got: 2} in errs
    end

    test "errors when insufficient non-nops" do
      buffer = List.duplicate(:nop_0, 20)
      assert {:error, errs} = CodeomeBuffer.validate(buffer)
      assert {:insufficient_non_nops, min: 10, got: 0} in errs
    end

    test "errors when too long" do
      buffer = List.duplicate(:push0, 501)
      assert {:error, errs} = CodeomeBuffer.validate(buffer)
      assert {:too_long, max: 500, got: 501} in errs
    end

    test "accumulates multiple errors" do
      assert {:error, errs} = CodeomeBuffer.validate([:nop_0, :nop_1])
      assert {:too_short, min: 5, got: 2} in errs
      assert {:insufficient_non_nops, min: 10, got: 0} in errs
    end
  end

  describe "from_codeome / to_codeome roundtrip" do
    test "round-trips" do
      original = Lenies.Codeome.from_list([:push0, :push1, :store])
      buffer = CodeomeBuffer.from_codeome(original)
      assert buffer == [:push0, :push1, :store]
      back = CodeomeBuffer.to_codeome(buffer)
      assert Lenies.Codeome.to_list(back) == [:push0, :push1, :store]
    end
  end

  describe "slice/2" do
    test "returns the inclusive range of opcodes" do
      assert CodeomeBuffer.slice([:a, :b, :c, :d], {1, 2}) == [:b, :c]
    end

    test "single-element range" do
      assert CodeomeBuffer.slice([:a, :b, :c], {0, 0}) == [:a]
    end

    test "clamps hi to the last index" do
      assert CodeomeBuffer.slice([:a, :b], {0, 9}) == [:a, :b]
    end

    test "empty buffer yields []" do
      assert CodeomeBuffer.slice([], {0, 0}) == []
    end

    test "lo past the end yields []" do
      assert CodeomeBuffer.slice([:a, :b], {5, 9}) == []
    end
  end

  describe "delete_range/2" do
    test "removes the inclusive range" do
      assert CodeomeBuffer.delete_range([:a, :b, :c, :d], {1, 2}) == [:a, :d]
    end

    test "deleting the whole buffer yields []" do
      assert CodeomeBuffer.delete_range([:a, :b], {0, 1}) == []
    end

    test "clamps hi beyond the end" do
      assert CodeomeBuffer.delete_range([:a, :b, :c], {1, 9}) == [:a]
    end

    test "empty buffer yields []" do
      assert CodeomeBuffer.delete_range([], {0, 0}) == []
    end

    test "lo past the end leaves the buffer unchanged (no-op)" do
      assert CodeomeBuffer.delete_range([:a, :b], {5, 9}) == [:a, :b]
    end
  end

  describe "insert_many/3" do
    test "inserts a list at the index" do
      assert CodeomeBuffer.insert_many([:a, :d], 1, [:b, :c]) == [:a, :b, :c, :d]
    end

    test "index 0 prepends" do
      assert CodeomeBuffer.insert_many([:c], 0, [:a, :b]) == [:a, :b, :c]
    end

    test "index past the end appends" do
      assert CodeomeBuffer.insert_many([:a], 9, [:b]) == [:a, :b]
    end

    test "inserting an empty list is a no-op" do
      assert CodeomeBuffer.insert_many([:a, :b], 1, []) == [:a, :b]
    end

    test "inserting into an empty buffer" do
      assert CodeomeBuffer.insert_many([], 0, [:a, :b]) == [:a, :b]
    end
  end

  describe "economics/3" do
    test "empty buffer has zero cost, zero gain" do
      e = CodeomeBuffer.economics([], 20, 10)
      assert e.cost == 0.0
      assert e.max_gain == 0.0
      assert e.net == 0.0
      assert e.n_eat == 0
      assert e.n_attack == 0
    end

    test "flat opcodes sum their static costs" do
      # add (0.2) + push0 (0.1) + sense_front (0.5) + move (2.0) = 2.8
      e = CodeomeBuffer.economics([:add, :push0, :sense_front, :move], 20, 10)
      assert e.cost == 2.8
      assert e.max_gain == 0.0
    end

    test "eat opcodes contribute eat_amount × count to max_gain and 2.0 each to cost" do
      e = CodeomeBuffer.economics([:eat, :eat, :eat], 20, 10)
      assert e.n_eat == 3
      assert e.max_gain == 60.0
      assert e.cost == 6.0
    end

    test "attack opcodes contribute attack_damage × count to max_gain" do
      e = CodeomeBuffer.economics([:attack, :attack], 20, 10)
      assert e.n_attack == 2
      assert e.max_gain == 20.0
      # 2 × attack = 2 × 5.0 = 10.0
      assert e.cost == 10.0
    end

    test "max_gain reflects current tuning eat_amount/attack_damage" do
      e = CodeomeBuffer.economics([:eat, :attack], 50, 25)
      assert e.max_gain == 75.0
    end

    test "template-jump cost scales with the run of nops following the jump" do
      # jmp_t followed by 3 nops, then push0 (breaks the template run)
      # cost = (0.2 + 0.05 × 3) + 3 × 0.1 + 0.1 = 0.35 + 0.30 + 0.10 = 0.75
      e = CodeomeBuffer.economics([:jmp_t, :nop_0, :nop_1, :nop_0, :push0], 20, 10)
      assert_in_delta e.cost, 0.75, 0.001
    end

    test "template-jump cost is clamped at template_max_len following nops" do
      original = Application.get_env(:lenies, :template_max_len)
      Application.put_env(:lenies, :template_max_len, 3)

      on_exit_fn = fn ->
        if original do
          Application.put_env(:lenies, :template_max_len, original)
        else
          Application.delete_env(:lenies, :template_max_len)
        end
      end

      # 5 nops after jz_t but only first 3 counted toward template_len
      # cost = (0.2 + 0.05 × 3) + 5 × 0.1 = 0.35 + 0.5 = 0.85
      try do
        e = CodeomeBuffer.economics([:jz_t, :nop_0, :nop_1, :nop_0, :nop_1, :nop_0], 20, 10)
        assert_in_delta e.cost, 0.85, 0.001
      after
        on_exit_fn.()
      end
    end

    test "allocate is priced with buffer length as size proxy" do
      buf = [:push0, :allocate, :divide] ++ List.duplicate(:nop_0, 7)
      # length = 10. allocate: 5.0 + 0.05 × 10 = 5.5
      # push0=0.1, divide=10.0, 7 nops × 0.1 = 0.7. Total = 5.5 + 0.1 + 10.0 + 0.7 = 16.3
      e = CodeomeBuffer.economics(buf, 20, 10)
      assert_in_delta e.cost, 16.3, 0.001
      assert e.alloc_size == 10
    end

    test "net is max_gain - cost, signed" do
      # 1 eat: cost 2.0, gain 20 → net +18.0
      e = CodeomeBuffer.economics([:eat], 20, 10)
      assert e.net == 18.0

      # 1 attack: cost 5.0, gain 10 → net +5.0
      e = CodeomeBuffer.economics([:attack], 20, 10)
      assert e.net == 5.0

      # 1 divide: cost 10.0, gain 0 → net -10.0
      e = CodeomeBuffer.economics([:divide], 20, 10)
      assert e.net == -10.0
    end
  end

  describe "move_range/3" do
    test "moves a range forward, adjusting for the removed elements" do
      assert CodeomeBuffer.move_range([:a, :b, :c, :d, :e], {1, 2}, 4) == [:a, :d, :b, :c, :e]
    end

    test "moves a range to the start" do
      assert CodeomeBuffer.move_range([:a, :b, :c, :d, :e], {1, 2}, 0) == [:b, :c, :a, :d, :e]
    end

    test "dropping inside the moved range is a no-op" do
      assert CodeomeBuffer.move_range([:a, :b, :c, :d, :e], {1, 2}, 2) == [:a, :b, :c, :d, :e]
    end

    test "moves a single-element range to the end" do
      assert CodeomeBuffer.move_range([:a, :b, :c], {0, 0}, 3) == [:b, :c, :a]
    end
  end
end
