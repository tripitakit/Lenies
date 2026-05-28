defmodule Lenies.SandboxesTest do
  use ExUnit.Case, async: false

  describe "world_id_for/1" do
    test "wraps a user id as a {:sandbox, id} tuple" do
      assert Lenies.Sandboxes.world_id_for(42) == {:sandbox, 42}
      assert Lenies.Sandboxes.world_id_for(1) == {:sandbox, 1}
    end
  end
end
