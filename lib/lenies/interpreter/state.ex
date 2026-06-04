defmodule Lenies.Interpreter.State do
  @moduledoc """
  Execution state of a Lenie's VM.

  Fields:
  - `ip`: instruction pointer into the Codeome (non-negative integer, wraps modulo size)
  - `stack`: list of integers, max 16 elements (top = head)
  - `slots`: 4 local memory slots (`%{0..3 => integer}`)
  - `dir`: current orientation `:n | :e | :s | :w`
  - `energy`: remaining energy (float, decremented by opcode costs)
  - `age`: incremented by 1 on each batch of K instructions (metabolic tick),
    not per instruction; exposed to programs via the `:sense_age` opcode
  - `pos`: position `{x, y}` on the grid
  - `call_stack`: IP history for `:call_t` / `:ret`
  - `plasmids`: list of `%Lenies.Plasmid{}` (a Lenie may carry several —
    `:make_plasmid` appends without limit and `:conjugate` spreads each).
    Mutated by `:make_plasmid` and `:conjugate`; the host Lenie process
    mirrors this into its own `state.plasmids` field via `age_and_continue/2`.
  """

  @type t :: %__MODULE__{
          ip: non_neg_integer(),
          stack: [integer()],
          slots: %{(0..3) => integer()},
          dir: :n | :e | :s | :w,
          energy: float(),
          age: non_neg_integer(),
          pos: {non_neg_integer(), non_neg_integer()},
          call_stack: [non_neg_integer()],
          plasmids: [Lenies.Plasmid.t()]
        }

  @stack_max 16
  @call_stack_max 32
  @slot_count 4

  defstruct ip: 0,
            stack: [],
            slots: %{0 => 0, 1 => 0, 2 => 0, 3 => 0},
            dir: :n,
            energy: 0.0,
            age: 0,
            pos: {0, 0},
            call_stack: [],
            plasmids: []

  def new(opts) do
    %__MODULE__{
      ip: Keyword.get(opts, :ip, 0),
      stack: Keyword.get(opts, :stack, []),
      slots: Keyword.get(opts, :slots, %{0 => 0, 1 => 0, 2 => 0, 3 => 0}),
      dir: Keyword.get(opts, :dir, :n),
      energy: Keyword.get(opts, :energy, 0.0) * 1.0,
      age: Keyword.get(opts, :age, 0),
      pos: Keyword.get(opts, :pos, {0, 0}),
      call_stack: Keyword.get(opts, :call_stack, []),
      plasmids: Keyword.get(opts, :plasmids, [])
    }
  end

  @spec push(t(), integer()) :: t()
  def push(%__MODULE__{stack: stack} = s, value) do
    new_stack = [value | stack]

    new_stack =
      if length(new_stack) > @stack_max do
        # remove the bottom (oldest) element
        Enum.take(new_stack, @stack_max)
      else
        new_stack
      end

    %{s | stack: new_stack}
  end

  @doc """
  Pops the top of the stack. On an empty stack returns `{0, state}` — this is
  intentional: the Codeome may evolve to pop from an empty stack, so we must
  be tolerant (no crash).
  """
  @spec pop(t()) :: {integer(), t()}
  def pop(%__MODULE__{stack: []} = s), do: {0, s}
  def pop(%__MODULE__{stack: [top | rest]} = s), do: {top, %{s | stack: rest}}

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

  @spec push_call(t(), non_neg_integer()) :: t()
  def push_call(%__MODULE__{call_stack: cs} = s, return_ip) do
    new_cs = [return_ip | cs] |> Enum.take(@call_stack_max)
    %{s | call_stack: new_cs}
  end

  @spec pop_call(t()) :: {non_neg_integer() | nil, t()}
  def pop_call(%__MODULE__{call_stack: []} = s), do: {nil, s}
  def pop_call(%__MODULE__{call_stack: [top | rest]} = s), do: {top, %{s | call_stack: rest}}

  @spec apply_cost(t(), float()) :: t()
  def apply_cost(%__MODULE__{energy: e} = s, cost), do: %{s | energy: e - cost}

  @doc "Advances the IP by `delta` positions, wrapping modulo `codeome_size`."
  @spec advance_ip(t(), non_neg_integer(), integer()) :: t()
  def advance_ip(%__MODULE__{ip: ip} = s, codeome_size, delta) do
    %{s | ip: Integer.mod(ip + delta, codeome_size)}
  end
end
