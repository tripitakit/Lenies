defmodule Lenies.Interpreter.State do
  @moduledoc """
  Stato di esecuzione della VM di un Lenie.

  Campi:
  - `ip`: instruction pointer nel Codeome (intero non negativo, wraps modulo size)
  - `stack`: lista di interi, max 16 elementi (top = head)
  - `slots`: 4 slot di memoria locale (`%{0..3 => integer}`)
  - `dir`: orientamento corrente `:n | :e | :s | :w`
  - `energy`: energia residua (float, sottratta dai costi opcode)
  - `age`: incrementato di 1 a ogni batch di K istruzioni (tick metabolico)
  - `pos`: posizione `{x, y}` sulla griglia
  - `call_stack`: storia IP per `:call_t` / `:ret`
  """

  @type t :: %__MODULE__{
          ip: non_neg_integer(),
          stack: [integer()],
          slots: %{(0..3) => integer()},
          dir: :n | :e | :s | :w,
          energy: float(),
          age: non_neg_integer(),
          pos: {non_neg_integer(), non_neg_integer()},
          call_stack: [non_neg_integer()]
        }

  @stack_max 16
  @slot_count 4

  defstruct ip: 0,
            stack: [],
            slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
            dir: :n,
            energy: 0.0,
            age: 0,
            pos: {0, 0},
            call_stack: []

  def new(opts) do
    %__MODULE__{
      ip: Keyword.get(opts, :ip, 0),
      stack: Keyword.get(opts, :stack, []),
      slots: Keyword.get(opts, :slots, %{0 => 0, 1 => 0, 2 => 0, 3 => 0}),
      dir: Keyword.get(opts, :dir, :n),
      energy: Keyword.get(opts, :energy, 0.0) * 1.0,
      age: Keyword.get(opts, :age, 0),
      pos: Keyword.get(opts, :pos, {0, 0}),
      call_stack: Keyword.get(opts, :call_stack, [])
    }
  end

  @spec push(t(), integer()) :: t()
  def push(%__MODULE__{stack: stack} = s, value) do
    new_stack = [value | stack]

    new_stack =
      if length(new_stack) > @stack_max do
        # rimuovi il bottom (più vecchio)
        Enum.take(new_stack, @stack_max)
      else
        new_stack
      end

    %{s | stack: new_stack}
  end

  @doc """
  Pop top dello stack. Su stack vuoto ritorna `{0, state}` — questo è
  voluto: il Codeome può evolvere a fare pop su stack vuoto, dobbiamo
  essere tolleranti (non crashare).
  """
  @spec pop(t()) :: {integer(), t()}
  def pop(%__MODULE__{stack: []} = s), do: {0, s}
  def pop(%__MODULE__{stack: [top | rest]} = s), do: {top, %{s | stack: rest}}

  @spec peek(t()) :: integer()
  def peek(%__MODULE__{stack: []}), do: 0
  def peek(%__MODULE__{stack: [top | _]}), do: top

  @spec store(t(), integer(), integer()) :: t()
  def store(%__MODULE__{slots: slots} = s, slot_idx, value) do
    idx = Integer.mod(slot_idx, @slot_count)
    %{s | slots: Map.put(slots, idx, value)}
  end

  @spec load(t(), integer()) :: integer()
  def load(%__MODULE__{slots: slots}, slot_idx) do
    idx = Integer.mod(slot_idx, @slot_count)
    Map.get(slots, idx, 0)
  end

  @spec apply_cost(t(), float()) :: t()
  def apply_cost(%__MODULE__{energy: e} = s, cost), do: %{s | energy: e - cost}

  @doc "Avanza l'IP di `delta` posizioni, con wrap modulo `codeome_size`."
  @spec advance_ip(t(), non_neg_integer(), integer()) :: t()
  def advance_ip(%__MODULE__{ip: ip} = s, codeome_size, delta) do
    %{s | ip: Integer.mod(ip + delta, codeome_size)}
  end
end
