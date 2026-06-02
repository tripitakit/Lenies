defmodule LeniesWeb.GridRenderer do
  @moduledoc """
  Backwards-compatible shim. The grid-encoding logic now lives in the domain
  layer as `Lenies.WorldFrame`, so a per-world `Lenies.WorldRenderer` process
  can encode each frame **once** and broadcast it to every viewer (instead of
  every LiveView socket recomputing the full 256×256 frame on its own tick).

  Existing callers (and tests) that reference `LeniesWeb.GridRenderer` keep
  working via these delegates.
  """

  defdelegate encode_layers(handle, grid), to: Lenies.WorldFrame
  defdelegate encode_payload(handle, grid), to: Lenies.WorldFrame
end
