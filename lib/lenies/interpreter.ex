defmodule Lenies.Interpreter do
  @moduledoc """
  La VM stack-based che esegue il Codeome di un Lenie.

  `step/2` esegue UN opcode (con costo energetico, avanzamento IP, eventuali
  effetti sullo stato), ritornando:
  - `{:cont, state}` — esecuzione continua
  - `{:wait_world, action, state}` — serve un'azione mondo (Lenie deve fare
    `GenServer.call(World, ...)`)
  - `{:halt, reason, state}` — Lenie morto (es. `:starvation`)

  `run_k_instructions/3` esegue fino a K istruzioni o fino al primo
  `:wait_world`/`:halt`.

  Vedi spec §4.
  """

  alias Lenies.Codeome
  alias Lenies.Codeome.Costs
  alias Lenies.Interpreter.State

  @type step_result ::
          {:cont, State.t()}
          | {:wait_world, term(), State.t()}
          | {:halt, atom(), State.t()}

  @doc """
  Esegue il prossimo opcode. Codeome vuoto → `{:halt, :empty_codeome, state}`.
  Energia ≤ 0 dopo l'opcode → `{:halt, :starvation, state}`.
  """
  @spec step(State.t(), Codeome.t()) :: step_result()
  def step(state, codeome) do
    size = Codeome.size(codeome)

    if size == 0 do
      {:halt, :empty_codeome, state}
    else
      op = Codeome.at(codeome, state.ip)
      dispatch(op, state, codeome, size)
    end
  end

  @doc "Esegue fino a `k` istruzioni o fino al primo wait_world/halt."
  @spec run_k_instructions(State.t(), Codeome.t(), pos_integer()) :: step_result()
  def run_k_instructions(state, _codeome, 0), do: {:cont, state}

  def run_k_instructions(state, codeome, k) when k > 0 do
    case step(state, codeome) do
      {:cont, new_state} -> run_k_instructions(new_state, codeome, k - 1)
      other -> other
    end
  end

  # ----- dispatch -----

  # Template/bit: nop_0 / nop_1 sono no-op a livello di interprete
  # (i loro effetti sono in template addressing)
  defp dispatch(op, state, _c, size) when op in [:nop_0, :nop_1] do
    advance_and_charge(op, state, size, 1)
  end

  # Stack / aritmetica
  defp dispatch(:push0, state, _c, size),
    do: state |> State.push(0) |> advance_and_charge(:push0, size, 1)

  defp dispatch(:push1, state, _c, size),
    do: state |> State.push(1) |> advance_and_charge(:push1, size, 1)

  defp dispatch(:pushN, state, _c, size) do
    state |> State.push(:rand.uniform(256) - 1) |> advance_and_charge(:pushN, size, 1)
  end

  defp dispatch(:dup, state, _c, size) do
    {top, s1} = State.pop(state)
    s1 |> State.push(top) |> State.push(top) |> advance_and_charge(:dup, size, 1)
  end

  defp dispatch(:drop, state, _c, size) do
    {_, s} = State.pop(state)
    advance_and_charge(s, :drop, size, 1)
  end

  defp dispatch(:swap, state, _c, size) do
    {a, s1} = State.pop(state)
    {b, s2} = State.pop(s1)
    s3 = s2 |> State.push(a) |> State.push(b)
    advance_and_charge(s3, :swap, size, 1)
  end

  defp dispatch(:add, state, _c, size), do: binop(state, :add, &(&1 + &2), size)
  defp dispatch(:sub, state, _c, size), do: binop(state, :sub, fn a, b -> b - a end, size)
  defp dispatch(:mul, state, _c, size), do: binop(state, :mul, &(&1 * &2), size)

  defp dispatch(:mod, state, _c, size) do
    {a, s1} = State.pop(state)
    {b, s2} = State.pop(s1)
    res = if a == 0, do: 0, else: Integer.mod(b, a)
    s2 |> State.push(res) |> advance_and_charge(:mod, size, 1)
  end

  # opcode sconosciuti → trattati come :nop_0
  defp dispatch(_unknown, state, _c, size), do: advance_and_charge(:nop_0, state, size, 1)

  # ----- helpers -----

  defp binop(state, op, fun, size) do
    {a, s1} = State.pop(state)
    {b, s2} = State.pop(s1)
    s2 |> State.push(fun.(a, b)) |> advance_and_charge(op, size, 1)
  end

  # Versione con state come primo argomento (per pipeline)
  defp advance_and_charge(state, op, size, advance_by) when is_atom(op) do
    advance_and_charge(op, state, size, advance_by)
  end

  defp advance_and_charge(op, state, _size, advance_by) when is_atom(op) do
    cost = Costs.cost(op, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> Map.update!(:ip, &(&1 + advance_by))

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:cont, new_state}
    end
  end
end
