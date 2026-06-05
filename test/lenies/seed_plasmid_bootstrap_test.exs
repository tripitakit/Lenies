defmodule Lenies.SeedPlasmidBootstrapTest do
  use ExUnit.Case, async: true

  test "built-in seeds keep plasmids out of the chromosome (no runtime duplicate)" do
    refute :make_plasmid in (Lenies.Codeomes.MinimalReplicator.codeome() |> Lenies.Codeome.to_list())
    refute :make_plasmid in (Lenies.Codeomes.Carnivore.codeome() |> Lenies.Codeome.to_list())
  end
end
