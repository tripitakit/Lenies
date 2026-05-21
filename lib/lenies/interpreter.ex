defmodule Lenies.Interpreter do
  @moduledoc """
  The stack-based VM that executes a Lenie's Codeome.

  `step/2` executes ONE opcode (with energy cost, IP advancement, and any
  effects on state), returning:
  - `{:cont, state}` — execution continues
  - `{:wait_world, action, state}` — a world action is required (the Lenie must
    call `GenServer.call(World, ...)`)
  - `{:halt, reason, state}` — Lenie is dead (e.g. `:starvation`)

  `run_k_instructions/3` runs up to K instructions or until the first
  `:wait_world`/`:halt`.

  See spec §4.
  """

  alias Lenies.Codeome
  alias Lenies.Codeome.Costs
  alias Lenies.Interpreter.{State, Template}

  @type step_result ::
          {:cont, State.t()}
          | {:wait_world, term(), State.t()}
          | {:halt, atom(), State.t()}

  @doc """
  Executes the next opcode. Empty Codeome → `{:halt, :empty_codeome, state}`.
  Energy ≤ 0 after the opcode → `{:halt, :starvation, state}`.
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

  @doc "Runs up to `k` instructions or until the first wait_world/halt."
  @spec run_k_instructions(State.t(), Codeome.t(), pos_integer()) :: step_result()
  def run_k_instructions(state, _codeome, 0), do: {:cont, state}

  def run_k_instructions(state, codeome, k) when k > 0 do
    case step(state, codeome) do
      {:cont, new_state} -> run_k_instructions(new_state, codeome, k - 1)
      other -> other
    end
  end

  # ----- dispatch -----

  # Template/bit: nop_0 / nop_1 are no-ops at the interpreter level
  # (their effects are in template addressing)
  defp dispatch(op, state, _c, size) when op in [:nop_0, :nop_1] do
    advance_and_charge(op, state, size, 1)
  end

  # Stack / arithmetic
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

  # Local memory
  defp dispatch(:store, state, _c, size) do
    {slot_idx, s1} = State.pop(state)
    {value, s2} = State.pop(s1)
    s2 |> State.store(slot_idx, value) |> advance_and_charge(:store, size, 1)
  end

  defp dispatch(:load, state, _c, size) do
    {slot_idx, s1} = State.pop(state)
    value = State.load(s1, slot_idx)
    s1 |> State.push(value) |> advance_and_charge(:load, size, 1)
  end

  # Orientation
  defp dispatch(:turn_left, state, _c, size) do
    new_dir =
      case state.dir do
        :n -> :w
        :w -> :s
        :s -> :e
        :e -> :n
      end

    %{state | dir: new_dir} |> advance_and_charge(:turn_left, size, 1)
  end

  defp dispatch(:turn_right, state, _c, size) do
    new_dir =
      case state.dir do
        :n -> :e
        :e -> :s
        :s -> :w
        :w -> :n
      end

    %{state | dir: new_dir} |> advance_and_charge(:turn_right, size, 1)
  end

  # Local sensing (does not touch the world)
  defp dispatch(:sense_self, state, _c, size) do
    state |> State.push(1) |> advance_and_charge(:sense_self, size, 1)
  end

  defp dispatch(:sense_energy, state, _c, size) do
    state |> State.push(trunc(state.energy)) |> advance_and_charge(:sense_energy, size, 1)
  end

  defp dispatch(:sense_age, state, _c, size) do
    state |> State.push(state.age) |> advance_and_charge(:sense_age, size, 1)
  end

  defp dispatch(:sense_size, state, _c, size) do
    state |> State.push(size) |> advance_and_charge(:sense_size, size, 1)
  end

  # Self-inspection
  defp dispatch(:get_ip, state, _c, size) do
    state |> State.push(state.ip) |> advance_and_charge(:get_ip, size, 1)
  end

  defp dispatch(:get_size, state, _c, size) do
    state |> State.push(size) |> advance_and_charge(:get_size, size, 1)
  end

  defp dispatch(:read_self, state, c, size) do
    {addr, s1} = State.pop(state)
    op = Codeome.at(c, addr)
    op_int = Lenies.Codeome.Opcodes.encode(op)
    s1 |> State.push(op_int) |> advance_and_charge(:read_self, size, 1)
  end

  # Controllo template-based
  defp dispatch(:jmp_t, state, codeome, size), do: do_jump(state, codeome, size, :jmp_t, :always)
  defp dispatch(:jz_t, state, codeome, size), do: do_jump(state, codeome, size, :jz_t, :zero)
  defp dispatch(:jnz_t, state, codeome, size), do: do_jump(state, codeome, size, :jnz_t, :nonzero)

  defp dispatch(:call_t, state, codeome, size) do
    {template, t_len} = Template.extract(codeome, state.ip + 1, template_max_len())
    return_ip = Integer.mod(state.ip + 1 + t_len, size)

    case Template.find_complement(codeome, template, state.ip, template_search_radius()) do
      {:ok, match_pos} ->
        target_ip = Integer.mod(match_pos + length(template), size)

        state
        |> State.push_call(return_ip)
        |> Map.put(:ip, target_ip)
        |> State.apply_cost(Costs.cost(:call_t, t_len))
        |> halt_if_dead()

      :not_found ->
        %{state | ip: return_ip}
        |> State.apply_cost(Costs.cost(:call_t, t_len))
        |> halt_if_dead()
    end
  end

  defp dispatch(:ret, state, _codeome, size) do
    case State.pop_call(state) do
      {nil, _} ->
        state
        |> State.advance_ip(size, 1)
        |> State.apply_cost(Costs.cost(:ret, 0))
        |> halt_if_dead()

      {return_ip, new_state} ->
        %{new_state | ip: return_ip}
        |> State.apply_cost(Costs.cost(:ret, 0))
        |> halt_if_dead()
    end
  end

  # World actions: the interpreter advances the IP and pays the cost, then returns
  # :wait_world. The Lenie process is responsible for calling the World and
  # applying the result (e.g. pushing the sensed value onto the stack,
  # updating pos on a successful :move).

  defp dispatch(:sense_front, state, _c, size) do
    cost = Costs.cost(:sense_front, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:sense_front, state.pos, state.dir}, new_state}
    end
  end

  defp dispatch(:move, state, _c, size) do
    cost = Costs.cost(:move, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:move, state.pos, state.dir}, new_state}
    end
  end

  defp dispatch(:eat, state, _c, size) do
    cost = Costs.cost(:eat, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:eat, state.pos}, new_state}
    end
  end

  # Replication: returns :wait_world. The Lenie calls the World and applies the result.

  defp dispatch(:allocate, state, _c, size) do
    {req_size, s1} = State.pop(state)
    cost = Costs.cost(:allocate, req_size)

    new_state =
      s1
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:allocate, req_size, state.pos, state.dir}, new_state}
    end
  end

  defp dispatch(:write_child, state, _c, size) do
    {opcode_int, s1} = State.pop(state)
    {child_addr, s2} = State.pop(s1)
    cost = Costs.cost(:write_child, 0)

    new_state =
      s2
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:write_child, opcode_int, child_addr}, new_state}
    end
  end

  defp dispatch(:divide, state, _c, size) do
    cost = Costs.cost(:divide, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:divide, new_state.energy, state.pos, state.dir}, new_state}
    end
  end

  # Predation: returns :wait_world. The Lenie calls the World and applies the result.

  defp dispatch(:attack, state, _c, size) do
    cost = Costs.cost(:attack, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, {:attack, state.pos, state.dir}, new_state}
    end
  end

  defp dispatch(:defend, state, _c, size) do
    cost = Costs.cost(:defend, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:wait_world, :defend, new_state}
    end
  end

  defp dispatch(:conjugate, state, _codeome, size) do
    # Transfer one carried plasmid, chosen uniformly at random among those
    # the Lenie holds (so a multi-plasmid carrier spreads each of them over
    # repeated encounters rather than only ever its first).
    plasmid_opcodes =
      case state.plasmids do
        [] -> []
        plasmids -> Enum.random(plasmids).opcodes
      end

    # IP advances; cost is applied by apply_world_action based on outcome.
    new_state = %{state | ip: rem(state.ip + 1, size)}
    {:wait_world, {:conjugate, state.pos, state.dir, plasmid_opcodes}, new_state}
  end

  # Stack on entry: [..., start_addr, length] with `length` on top. The pop
  # order below mirrors that — `length` first, then `start_addr` — so that
  # the producing program writes them push(start_addr); push(length); make_plasmid.
  defp dispatch(:make_plasmid, state, codeome, size) do
    {length, s1} = State.pop(state)
    {start_addr, s2} = State.pop(s1)

    if Lenies.Plasmid.valid_length?(length) do
      ops = for i <- 0..(length - 1), do: Codeome.at(codeome, start_addr + i)
      new_plasmid = Lenies.Plasmid.new(ops)
      cost = Costs.cost(:make_plasmid, length)

      new_state = %{s2 | plasmids: [new_plasmid]}

      new_state
      |> State.push(1)
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)
      |> halt_if_dead()
    else
      cost = Costs.cost(:make_plasmid, 0)

      s2
      |> State.push(0)
      |> State.apply_cost(cost)
      |> State.advance_ip(size, 1)
      |> halt_if_dead()
    end
  end

  # unknown opcodes → treated as :nop_0
  defp dispatch(_unknown, state, _c, size), do: advance_and_charge(:nop_0, state, size, 1)

  # ----- helpers -----

  defp binop(state, op, fun, size) do
    {a, s1} = State.pop(state)
    {b, s2} = State.pop(s1)
    s2 |> State.push(fun.(a, b)) |> advance_and_charge(op, size, 1)
  end

  # Version with state as the first argument (for pipelines)
  defp advance_and_charge(state, op, size, advance_by) when is_atom(op) do
    advance_and_charge(op, state, size, advance_by)
  end

  defp advance_and_charge(op, state, size, advance_by) when is_atom(op) do
    cost = Costs.cost(op, 0)

    new_state =
      state
      |> State.apply_cost(cost)
      |> State.advance_ip(size, advance_by)

    if new_state.energy <= 0 do
      {:halt, :starvation, new_state}
    else
      {:cont, new_state}
    end
  end

  defp do_jump(state, codeome, size, op, condition) do
    {template, t_len} = Template.extract(codeome, state.ip + 1, template_max_len())
    skip_to = Integer.mod(state.ip + 1 + t_len, size)

    should_jump =
      case condition do
        :always ->
          true

        :zero ->
          {top, _} = State.pop(state)
          top == 0

        :nonzero ->
          {top, _} = State.pop(state)
          top != 0
      end

    # For conditional jumps, consume the stack value
    state_after_pop =
      case condition do
        :always ->
          state

        _ ->
          {_, s} = State.pop(state)
          s
      end

    target_ip =
      if should_jump and t_len > 0 do
        case Template.find_complement(codeome, template, state.ip, template_search_radius()) do
          {:ok, match_pos} -> Integer.mod(match_pos + length(template), size)
          :not_found -> skip_to
        end
      else
        skip_to
      end

    %{state_after_pop | ip: target_ip}
    |> State.apply_cost(Costs.cost(op, t_len))
    |> halt_if_dead()
  end

  defp halt_if_dead(state) do
    if state.energy <= 0 do
      {:halt, :starvation, state}
    else
      {:cont, state}
    end
  end

  defp template_max_len, do: Application.get_env(:lenies, :template_max_len, 8)
  defp template_search_radius, do: Application.get_env(:lenies, :template_search_radius, 256)
end
