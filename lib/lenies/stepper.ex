defmodule Lenies.Stepper do
  @moduledoc """
  Pure-functional codeome debugger. See spec at
  `docs/superpowers/specs/2026-06-01-codeome-stepper-design.md`.

  Owns a `%Stepper{}` session value; every public function takes and
  returns a session — no GenServer, no PubSub.
  """

  alias Lenies.{Codeome, Interpreter, Stepper.World}
  alias Lenies.Interpreter.State

  @max_history 50
  @safety_cap 10_000
  @debug_id "debug"

  defstruct codeome: nil,
            interp: nil,
            world: nil,
            history: [],
            breakpoints: MapSet.new(),
            step_count: 0,
            status: :ready,
            halt_reason: nil,
            last_action: nil,
            place_seed_mode: nil

  @type t :: %__MODULE__{
          codeome: Codeome.t(),
          interp: State.t(),
          world: World.t(),
          history: [map],
          breakpoints: MapSet.t(non_neg_integer),
          step_count: non_neg_integer,
          status: :ready | :running | :paused | :halted | :breakpoint_hit | :safety_cap_reached,
          halt_reason: nil | atom,
          last_action: nil | map,
          place_seed_mode: nil | map
        }

  @spec start_session(Codeome.t(), keyword) :: t()
  def start_session(%Codeome{} = codeome, opts \\ []) do
    energy = Keyword.get(opts, :energy, 5000.0) * 1.0
    pos = Keyword.get(opts, :pos, {32, 32})
    dir = Keyword.get(opts, :dir, :n)

    interp = %State{
      ip: 0,
      stack: [],
      slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
      call_stack: [],
      age: 0,
      energy: energy,
      pos: pos,
      dir: dir,
      plasmids: []
    }

    debug_lenie = %{
      codeome: codeome,
      pos: pos,
      dir: dir,
      energy: energy,
      kind: :debug,
      plasmids: []
    }

    {:ok, world} = World.new() |> World.place_lenie(@debug_id, debug_lenie)

    %__MODULE__{codeome: codeome, interp: interp, world: world}
  end

  @spec step(t()) :: {:ok, t()}
  def step(%__MODULE__{status: status} = session)
      when status in [:halted, :safety_cap_reached] do
    {:ok, session}
  end

  def step(%__MODULE__{} = session) do
    snapshot = %{interp: session.interp, world: session.world}
    new_history = [snapshot | session.history] |> Enum.take(@max_history)

    case Interpreter.step(session.interp, session.codeome) do
      {:cont, new_interp} ->
        {:ok,
         %{
           session
           | interp: new_interp,
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
             world: new_world,
             history: new_history,
             step_count: session.step_count + 1,
             status: :ready
         }}

      {:halt, reason, new_interp} ->
        {:ok,
         %{
           session
           | interp: new_interp,
             history: new_history,
             step_count: session.step_count + 1,
             status: :halted,
             halt_reason: reason
         }}
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

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = session) do
    seeds =
      session.world.lenies
      |> Enum.filter(fn {_id, l} -> l.kind == :seed end)

    fresh = start_session(session.codeome, [])

    new_world =
      Enum.reduce(seeds, fresh.world, fn {id, seed}, acc ->
        case World.place_lenie(acc, id, seed) do
          {:ok, w} -> w
          {:error, _} -> acc
        end
      end)

    %{fresh | world: new_world, breakpoints: session.breakpoints}
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
end
