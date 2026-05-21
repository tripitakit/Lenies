defmodule Lenies.SlugTest do
  use ExUnit.Case, async: true

  test "lowercases and hyphenates" do
    assert Lenies.Slug.slugify("My Replicator V1") == "my-replicator-v1"
  end

  test "Hello World produces hello-world" do
    assert Lenies.Slug.slugify("Hello World") == "hello-world"
  end

  test "collapses non-alphanumeric runs and trims edge hyphens" do
    assert Lenies.Slug.slugify("  Foo!!__bar  ") == "foo-bar"
  end

  test "all-symbol input returns the fallback non-empty slug" do
    result = Lenies.Slug.slugify("###")
    assert result != ""
    assert result == "x"
  end

  test "empty string input returns the fallback non-empty slug" do
    result = Lenies.Slug.slugify("")
    assert result != ""
    assert result == "x"
  end
end
