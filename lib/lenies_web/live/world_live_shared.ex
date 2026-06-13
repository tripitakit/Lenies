defmodule LeniesWeb.WorldLiveShared do
  @moduledoc """
  Presentation helpers shared by the two world LiveViews — `DashboardLive`
  (the Sandbox) and `ArenaLive` (the public Arena).

  Both render the same world model, so the species-table formatting/sorting
  and the cursor hover-tooltip payload were previously copy-pasted in both
  modules. This module is the single home for that shared logic; ETS access
  goes through `Lenies.World.Query`, never directly.

  The functions are `import`ed into both LiveViews so existing call sites —
  including bare calls inside `~H` templates like `format_count(@n)` — keep
  working unchanged. World-specific logic that genuinely differs between the
  two (e.g. Arena folds per-row ownership into its stream signature) stays
  in the respective LiveView.
  """

  alias Lenies.World.Query

  # Pristine-codeome hashes for every built-in seed, computed once at module
  # load. Custom user seeds aren't covered because their pristine codeome
  # lives in the per-user `Lenies.Collection` (the user could even edit and
  # save back at any time) — for those we always show the "evolved from"
  # form because we can't reliably know what "pristine" means.
  @builtin_pristine_hashes Map.new(
                             Lenies.Seeds.all(),
                             fn s -> {s.name, Lenies.Codeome.hash(s.codeome)} end
                           )

  @doc """
  Build the hover-tooltip payload for the Lenie (if any) at grid cell
  `{x, y}`. The shape is the JS contract for the `lenie_hover_info` pushed
  event; `present: false` means the cell is empty / the world is gone.
  """
  @spec lenie_hover_payload(Lenies.WorldHandle.t() | nil, integer, integer) :: map
  def lenie_hover_payload(handle, x, y) do
    case Query.lenie_snap_at(handle, x, y) do
      {:ok, snap} ->
        %{
          x: x,
          y: y,
          present: true,
          seed_origin: Map.get(snap, :seed_origin),
          age: Map.get(snap, :age, 0),
          energy: trunc(Map.get(snap, :energy, 0.0)),
          codeome_hash: Map.get(snap, :codeome_hash)
        }

      :error ->
        %{x: x, y: y, present: false}
    end
  end

  @doc """
  Aggregate the world's species and split off the top `n`. Returns
  `{top_n, all, total_count}`.
  """
  def aggregate_with_top(handle, n) do
    all = Lenies.Species.aggregate(handle)
    {Enum.take(all, n), all, length(all)}
  end

  @doc "Compact human count: 1234 -> \"1.2k\", 2_000_000 -> \"2.0M\"."
  def format_count(n) when is_integer(n) and n >= 0 do
    cond do
      n < 1_000 -> Integer.to_string(n)
      n < 1_000_000 -> "#{Float.round(n / 1_000, 1)}k"
      n < 1_000_000_000 -> "#{Float.round(n / 1_000_000, 2)}M"
      true -> "#{Float.round(n / 1_000_000_000, 2)}B"
    end
  end

  def format_count(n) when is_float(n), do: format_count(trunc(n))
  def format_count(_), do: "0"

  @doc """
  Render the Seed column. Three cases:
    - `seed_origin` is nil → "—" (Lenie pre-feature or untracked).
    - the species' hash matches the pristine hash of `seed_origin` → bare
      seed name (Lenie hasn't drifted from its seed).
    - otherwise → "evolved from <seed_origin>" (mutation / copy-error
      descendant).
  """
  def format_seed_origin(%{seed_origin: nil}), do: "—"

  def format_seed_origin(%{seed_origin: origin, hash: hash}) do
    case Map.get(@builtin_pristine_hashes, origin) do
      ^hash -> origin
      _ -> "evolved from " <> origin
    end
  end

  def format_seed_origin(_), do: "—"

  @doc """
  Order the species rows by the active column/direction. `Enum.sort_by/3`
  handles both numeric keys and the (downcased) seed-name string via term
  ordering. Call before streaming so the client receives pre-sorted rows.
  """
  def sort_species(species, sort_by, sort_dir) do
    Enum.sort_by(species, sort_key_fun(sort_by), sort_dir)
  end

  @doc "Sort-key extractor for a given column."
  def sort_key_fun(:seed), do: fn sp -> sp |> format_seed_origin() |> String.downcase() end
  def sort_key_fun(:size), do: & &1.size
  def sort_key_fun(:cost), do: & &1.cost
  def sort_key_fun(:gain), do: & &1.max_gain
  def sort_key_fun(:net), do: &(&1.max_gain - &1.cost)
  def sort_key_fun(:population), do: & &1.population
  def sort_key_fun(:avg_generation), do: & &1.avg_generation

  @doc "Sort indicator next to the active column header."
  def sort_arrow(active, :asc, active), do: " ▲"
  def sort_arrow(active, :desc, active), do: " ▼"
  def sort_arrow(_by, _dir, _col), do: ""

  @doc "Flip a sort direction."
  def toggle_dir(:asc), do: :desc
  def toggle_dir(:desc), do: :asc

  @doc """
  Default direction per column: seed is alphabetical (asc); numeric columns
  lead with the largest value (desc), which is what a user scanning for the
  dominant / most-expensive species expects.
  """
  def default_sort_dir(:seed), do: :asc
  def default_sort_dir(_), do: :desc

  @doc """
  Net = max_gain − cost for one linear pass. "+" prefix on positive so the
  sign reads at a glance (color carries it too: green ≥ 0, red < 0).
  """
  def format_net(net) when net > 0, do: "+" <> format_energy(net)
  def format_net(net), do: format_energy(net)

  @doc "Tailwind text color for a net-energy value."
  def net_color(net) when net < 0, do: "text-rose-300"
  def net_color(_net), do: "text-emerald-300"

  @doc """
  Compact energy display for the species table: integer when whole, one
  decimal otherwise. Avoids `0.0` clutter for codeomes with no eat/attack
  opcodes and keeps the column width predictable.
  """
  def format_energy(n) when is_integer(n), do: Integer.to_string(n)

  def format_energy(n) when is_float(n) do
    rounded = Float.round(n, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  def format_energy(_), do: "0"
end
