defmodule Lenies.MutatorTest do
  use ExUnit.Case, async: true

  alias Lenies.Mutator

  describe "copy_outcome/1" do
    test "with all rates at 0 always returns :write" do
      outcome = Mutator.copy_outcome(%{substitution: 0.0, insert: 0.0, delete: 0.0})
      assert outcome == :write
    end

    test "with substitution rate = 1.0 always returns :substitute" do
      outcome = Mutator.copy_outcome(%{substitution: 1.0, insert: 0.0, delete: 0.0})
      assert outcome == :substitute
    end

    test "with insert rate = 1.0 always returns :insert" do
      outcome = Mutator.copy_outcome(%{substitution: 0.0, insert: 1.0, delete: 0.0})
      assert outcome == :insert
    end

    test "with delete rate = 1.0 always returns :delete" do
      outcome = Mutator.copy_outcome(%{substitution: 0.0, insert: 0.0, delete: 1.0})
      assert outcome == :delete
    end

    test "statistical: substitution rate 0.5 produces ~50% :substitute outcomes" do
      rates = %{substitution: 0.5, insert: 0.0, delete: 0.0}
      results = for _ <- 1..10_000, do: Mutator.copy_outcome(rates)
      subs = Enum.count(results, &(&1 == :substitute))
      # 5000 expected, allow ±5% (250) deviation
      assert_in_delta subs, 5000, 250
    end
  end

  describe "random_opcode/0" do
    test "returns a known opcode from the whitelist" do
      for _ <- 1..100 do
        op = Mutator.random_opcode()
        assert Lenies.Codeome.Opcodes.known?(op)
      end
    end
  end

  describe "background_mutation/2" do
    test "applies a single random substitution to a Codeome" do
      original = Lenies.Codeome.from_list([:nop_0, :nop_0, :nop_0, :nop_0, :nop_0])
      mutated = Mutator.background_mutation(original)

      # Exactly one position should differ (probabilistically: substitution may pick the same opcode)
      diff_count =
        Enum.zip(Lenies.Codeome.to_list(original), Lenies.Codeome.to_list(mutated))
        |> Enum.count(fn {a, b} -> a != b end)

      assert diff_count <= 1, "expected at most 1 position to change, got #{diff_count}"
      assert Lenies.Codeome.size(mutated) == 5
    end
  end

  describe "background_mutation_list/1" do
    test "single substitution on a non-empty list" do
      original = [:eat, :move, :turn_left, :turn_right]
      mutated = Mutator.background_mutation_list(original)
      assert length(mutated) == 4
      diff_count = Enum.zip(original, mutated) |> Enum.count(fn {a, b} -> a != b end)
      assert diff_count <= 1
    end

    test "empty list is returned unchanged" do
      assert Mutator.background_mutation_list([]) == []
    end
  end

  describe "insert_at/4" do
    # MH2: lock the exact truncation behaviour of the :insert copy-mutation path.
    # Inserting at idx places the new op there, shifts elements right, and DROPS
    # the original last element — tuple size is preserved.

    test "inserts op at index 0, shifts right, drops last element" do
      # {:a,:b,:c,:d} insert :x at 0 → {:x,:a,:b,:c} (drops :d)
      result = Mutator.insert_at({:a, :b, :c, :d}, 0, :x, 4)
      assert result == {:x, :a, :b, :c}
      assert tuple_size(result) == 4
    end

    test "inserts op at a middle index, shifts tail right, drops last element" do
      # {:a,:b,:c,:d} insert :x at 1 → {:a,:x,:b,:c} (drops :d)
      result = Mutator.insert_at({:a, :b, :c, :d}, 1, :x, 4)
      assert result == {:a, :x, :b, :c}
      assert tuple_size(result) == 4
    end

    test "inserts op at last index, drops the original last element" do
      # {:a,:b,:c,:d} insert :x at 3 → {:a,:b,:c,:x} (drops :d)
      result = Mutator.insert_at({:a, :b, :c, :d}, 3, :x, 4)
      assert result == {:a, :b, :c, :x}
      assert tuple_size(result) == 4
    end

    test "index out of range wraps via Integer.mod" do
      # idx=5 mod 4 = 1, same as inserting at 1
      result = Mutator.insert_at({:a, :b, :c, :d}, 5, :x, 4)
      assert result == {:a, :x, :b, :c}
      assert tuple_size(result) == 4
    end
  end

  describe "copy_mutate_list/4" do
    test "rate 0.0 reproduces the input exactly" do
      original = [:eat, :move, :turn_left]
      assert Mutator.copy_mutate_list(original, 0.0, 0.0, 0.0) == original
    end

    test "rate 1.0 substitution changes every opcode" do
      # With sub=1.0, every opcode is replaced by a random one from the
      # whitelist. The replacement might match by chance, but for 100
      # opcodes it's overwhelmingly unlikely all 100 match.
      original = List.duplicate(:eat, 100)
      mutated = Mutator.copy_mutate_list(original, 1.0, 0.0, 0.0)
      assert length(mutated) == 100
      refute mutated == original
    end

    test "rate 1.0 delete returns empty list" do
      original = List.duplicate(:eat, 20)
      assert Mutator.copy_mutate_list(original, 0.0, 0.0, 1.0) == []
    end

    test "rate 1.0 insert doubles the list length" do
      original = List.duplicate(:eat, 5)
      mutated = Mutator.copy_mutate_list(original, 0.0, 1.0, 0.0)
      assert length(mutated) == 10
    end
  end
end
