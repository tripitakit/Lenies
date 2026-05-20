defmodule Lenies.SlugTest do
  use ExUnit.Case, async: true

  test "lowercases and hyphenates" do
    assert Lenies.Slug.slugify("My Replicator V1") == "my-replicator-v1"
  end

  test "collapses non-alphanumeric runs and trims edge hyphens" do
    assert Lenies.Slug.slugify("  Foo!!__bar  ") == "foo-bar"
  end

  test "empty / all-symbol input yields empty string" do
    assert Lenies.Slug.slugify("***") == ""
    assert Lenies.Slug.slugify("") == ""
  end
end
