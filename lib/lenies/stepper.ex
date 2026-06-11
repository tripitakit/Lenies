defmodule Lenies.Stepper do
  @moduledoc """
  Pure-functional codeome debugger. See spec at
  `docs/superpowers/specs/2026-06-01-codeome-stepper-design.md`.

  Owns a `%Stepper{}` session value; every public function takes and
  returns a session — no GenServer, no PubSub.
  """

  alias Lenies.{Codeome, Interpreter, Lenie, Plasmid, Stepper.World}
  alias Lenies.Interpreter.State

  @max_history 50
  @safety_cap 10_000
  @debug_id "debug"

  defstruct codeome: nil,
            exec_codeome: nil,
            interp: nil,
            world: nil,
            history: [],
            breakpoints: MapSet.new(),
            step_count: 0,
            status: :ready,
            halt_reason: nil,
            last_action: nil,
            place_seed_mode: nil,
            initial_plasmids: [],
            resource_seed: nil

  @type t :: %__MODULE__{
          codeome: Codeome.t(),
          exec_codeome: Codeome.t(),
          interp: State.t(),
          world: World.t(),
          history: [map],
          breakpoints: MapSet.t(non_neg_integer),
          step_count: non_neg_integer,
          status: :ready | :running | :paused | :halted | :breakpoint_hit | :safety_cap_reached,
          halt_reason: nil | atom,
          last_action: nil | map,
          place_seed_mode: nil | map,
          initial_plasmids: [Lenies.Plasmid.t()],
          resource_seed: nil | integer
        }

  @spec start_session(Codeome.t(), keyword) :: t()
  def start_session(%Codeome{} = codeome, opts \\ []) do
    energy = Keyword.get(opts, :energy, 5000.0) * 1.0
    pos = Keyword.get(opts, :pos, {32, 32})
    dir = Keyword.get(opts, :dir, :n)
    plasmids = Keyword.get(opts, :plasmids, [])

    interp = %State{
      ip: 0,
      stack: [],
      slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
      call_stack: [],
      age: 0,
      energy: energy,
      pos: pos,
      dir: dir,
      plasmids: plasmids
    }

    debug_lenie = %{
      codeome: codeome,
      pos: pos,
      dir: dir,
      energy: energy,
      kind: :debug,
      plasmids: plasmids
    }

    resource_seed = Keyword.get(opts, :resource_seed, :rand.uniform(2_147_483_647))

    {:ok, world} =
      World.new()
      |> World.seed_resources(resource_seed)
      |> World.place_lenie(@debug_id, debug_lenie)

    %__MODULE__{
      codeome: codeome,
      exec_codeome: Lenie.build_exec_codeome(codeome, plasmids),
      interp: interp,
      world: world,
      initial_plasmids: plasmids,
      resource_seed: resource_seed
    }
  end

  @doc """
  Start offsets (in exec_codeome index space) of each carried-plasmid region:
  `chromo_len`, `chromo_len + len(p1)`, … Empty when no plasmids. Used by the
  UI to draw a separator before each plasmid region.
  """
  @spec plasmid_region_starts(t()) :: [non_neg_integer()]
  def plasmid_region_starts(%__MODULE__{} = session) do
    chromo_len = Codeome.size(session.codeome)

    session.interp.plasmids
    |> Enum.reduce({chromo_len, []}, fn %Plasmid{opcodes: ops}, {offset, acc} ->
      {offset + length(ops), [offset | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @spec step(t()) :: {:ok, t()}
  def step(%__MODULE__{status: status} = session)
      when status in [:halted, :safety_cap_reached] do
    {:ok, session}
  end

  def step(%__MODULE__{} = session) do
    snapshot = %{interp: session.interp, world: session.world, exec_codeome: session.exec_codeome}
    new_history = [snapshot | session.history] |> Enum.take(@max_history)

    case Interpreter.step(session.interp, session.exec_codeome) do
      {:cont, new_interp} ->
        {:ok,
         %{
           session
           | interp: new_interp,
             exec_codeome: rebuilt_exec(session, new_interp),
             world: sync_debug_lenie(session.world, new_interp),
             history: new_history,
             step_count: session.step_count + 1,
             status: :ready
         }}

      {:wait_world, action, new_interp} ->
        {:ok, new_world, resolved_interp} =
          World.apply_action(action, session.world, new_interp, @debug_id)

        {:ok,
         %{
           session
           | interp: resolved_interp,
             exec_codeome: rebuilt_exec(session, resolved_interp),
             world: sync_debug_lenie(new_world, resolved_interp),
             history: new_history,
             step_count: session.step_count + 1,
             status: :ready
         }}

      {:halt, reason, new_interp} ->
        {:ok,
         %{
           session
           | interp: new_interp,
             exec_codeome: rebuilt_exec(session, new_interp),
             history: new_history,
             step_count: session.step_count + 1,
             status: :halted,
             halt_reason: reason
         }}
    end
  end

  # Rebuild exec_codeome only when a step changed the carried plasmid list
  # (`:make_plasmid` / incoming conjugation). Cheap structural compare on a
  # short list — mirrors Lenie.age_and_continue/2.
  defp rebuilt_exec(%__MODULE__{} = session, new_interp) do
    if new_interp.plasmids == session.interp.plasmids do
      session.exec_codeome
    else
      Lenie.build_exec_codeome(session.codeome, new_interp.plasmids)
    end
  end

  # Keep the debug Lenie's world record (dir + pos) aligned with the interpreter
  # so the minimap renders the *current* facing. `:move` already syncs pos; this
  # also propagates `turn` (dir), which arrives via the :cont branch that never
  # otherwise touches the world.
  defp sync_debug_lenie(%World{lenies: lenies} = world, interp) do
    case Map.get(lenies, @debug_id) do
      nil ->
        world

      rec ->
        %{world | lenies: Map.put(lenies, @debug_id, %{rec | dir: interp.dir, pos: interp.pos})}
    end
  end

  @spec step_back(t()) :: {:ok, t()}
  def step_back(%__MODULE__{history: []} = session), do: {:ok, session}

  def step_back(%__MODULE__{history: [snap | rest]} = session) do
    {:ok,
     %{
       session
       | interp: snap.interp,
         world: snap.world,
         exec_codeome: snap.exec_codeome,
         history: rest,
         step_count: max(0, session.step_count - 1),
         status: :ready,
         halt_reason: nil
     }}
  end

  @spec run(t(), keyword) :: {:ok, t()}
  def run(%__MODULE__{} = session, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @safety_cap)
    do_run(session, 0, max_steps)
  end

  defp do_run(%__MODULE__{status: status} = session, _i, _max)
       when status in [:halted, :safety_cap_reached] do
    {:ok, session}
  end

  defp do_run(%__MODULE__{} = session, i, max_steps) when i >= max_steps do
    status = if session.step_count >= @safety_cap, do: :safety_cap_reached, else: :paused
    {:ok, %{session | status: status}}
  end

  defp do_run(%__MODULE__{} = session, i, max_steps) do
    {:ok, next} = step(session)

    cond do
      next.status == :halted ->
        {:ok, next}

      MapSet.member?(next.breakpoints, next.interp.ip) ->
        {:ok, %{next | status: :breakpoint_hit}}

      true ->
        do_run(next, i + 1, max_steps)
    end
  end

  @spec toggle_breakpoint(t(), non_neg_integer) :: t()
  def toggle_breakpoint(%__MODULE__{breakpoints: bps} = session, ip)
      when is_integer(ip) and ip >= 0 do
    new_bps = if MapSet.member?(bps, ip), do: MapSet.delete(bps, ip), else: MapSet.put(bps, ip)
    %{session | breakpoints: new_bps}
  end

  @doc """
  Fresh session from `new_codeome` (+ `:plasmids`), preserving the
  mini-world scenario: placed seed Lenies are re-placed at their
  coordinates and the resource seed is kept, so iterating on a codeome
  does not force the user to rebuild the scene. Breakpoints are NOT
  carried over implicitly — pass pre-remapped ones via `:breakpoints`
  (an edit changes the index space, so the caller owns the mapping).
  Always comes up `:ready` at step 0: a hot-restart must never resume
  RUN by surprise.
  """
  @spec restart(t(), Codeome.t(), keyword) :: t()
  def restart(%__MODULE__{} = session, %Codeome{} = new_codeome, opts \\ []) do
    plasmids = Keyword.get(opts, :plasmids, [])
    breakpoints = Keyword.get(opts, :breakpoints, MapSet.new())

    seeds =
      session.world.lenies
      |> Enum.filter(fn {_id, l} -> l.kind == :seed end)

    fresh =
      start_session(new_codeome,
        plasmids: plasmids,
        resource_seed: session.resource_seed
      )

    new_world =
      Enum.reduce(seeds, fresh.world, fn {id, seed}, acc ->
        case World.place_lenie(acc, id, seed) do
          {:ok, w} -> w
          {:error, _} -> acc
        end
      end)

    %{fresh | world: new_world, breakpoints: breakpoints}
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = session) do
    restart(session, session.codeome,
      plasmids: session.initial_plasmids,
      breakpoints: session.breakpoints
    )
  end

  @spec place_seed(t(), map, {non_neg_integer, non_neg_integer}) ::
          {:ok, t()} | {:error, atom}
  def place_seed(%__MODULE__{} = session, seed, {x, y}) when is_map(seed) do
    seed_id = "seed-#{:erlang.unique_integer([:positive])}"

    lenie = %{
      codeome: Map.fetch!(seed, :codeome),
      pos: {x, y},
      dir: :n,
      energy: 500.0,
      kind: :seed,
      plasmids: Map.get(seed, :plasmids, [])
    }

    case World.place_lenie(session.world, seed_id, lenie) do
      {:ok, new_world} -> {:ok, %{session | world: new_world}}
      {:error, _} = err -> err
    end
  end

  @spec set_place_seed_mode(t(), nil | term) :: t()
  def set_place_seed_mode(%__MODULE__{} = session, nil),
    do: %{session | place_seed_mode: nil}

  def set_place_seed_mode(%__MODULE__{} = session, seed_id),
    do: %{session | place_seed_mode: %{seed_id: seed_id}}

  @doc "Tick delay (ms) for a RUN speed in opcodes/sec. Clamps speed to >= 1."
  @spec delay_ms_for(integer()) :: pos_integer()
  def delay_ms_for(speed) do
    round(1000 / max(speed, 1))
  end

  @doc """
  The live world's effective execution rate in opcodes/sec, derived from config
  (`interpreter_steps_per_batch` over `lenie_metabolize_delay_ms`). Used as the
  RUN slider's maximum ("world speed"). Falls back to 100 when the inter-batch
  delay is 0 (dev/test), so the slider has a stable, finite max.
  """
  @spec world_ops_per_sec() :: pos_integer()
  def world_ops_per_sec do
    steps = Application.get_env(:lenies, :interpreter_steps_per_batch, 10)
    delay = Application.get_env(:lenies, :lenie_metabolize_delay_ms, 0)
    if delay > 0, do: round(steps * 1000 / delay), else: 100
  end
end
