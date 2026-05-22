defmodule LeniesWeb.JumpTargets do
  @moduledoc """
  Static, runtime-faithful computation of where each template jump in a codeome
  buffer lands. Reuses `Lenies.Interpreter.Template` so the editor shows exactly
  what the interpreter will do at the same `template_max_len` /
  `template_search_radius` tuning.
  """

  alias Lenies.Codeome
  alias Lenies.Interpreter.Template

  @jumps [:jmp_t, :jz_t, :jnz_t, :call_t]

  @doc "The template-jump opcodes (`:jmp_t`, `:jz_t`, `:jnz_t`, `:call_t`)."
  @spec jump_opcodes() :: [atom()]
  def jump_opcodes, do: @jumps

  @doc """
  Map of `jump_index => {:ok, target_index} | :not_found` for every template
  jump in `buffer`. The target is computed exactly as the interpreter does:
  extract the nop template after the jump, then search for its complement
  (forward up to `radius`, then backward), with toroidal wraparound.
  """
  @spec targets([atom()]) :: %{non_neg_integer() => {:ok, non_neg_integer()} | :not_found}
  def targets(buffer) when is_list(buffer) do
    codeome = Codeome.from_list(buffer)
    max_len = Application.get_env(:lenies, :template_max_len, 8)
    radius = Application.get_env(:lenies, :template_search_radius, 256)

    buffer
    |> Enum.with_index()
    |> Enum.filter(fn {op, _i} -> op in @jumps end)
    |> Map.new(fn {_op, i} ->
      {template, _len} = Template.extract(codeome, i + 1, max_len)
      {i, Template.find_complement(codeome, template, i, radius)}
    end)
  end
end
