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
end
