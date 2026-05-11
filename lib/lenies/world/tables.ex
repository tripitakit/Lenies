defmodule Lenies.World.Tables do
  @moduledoc """
  Crea e gestisce le tabelle ETS del progetto.

  Convenzione di ownership: il chiamante (`Lenies.World` in produzione) deve
  invocare `create_all/0` dal suo `init/1` per essere proprietario delle tabelle.
  Tutte le tabelle sono `:set`, `:named_table`, `:public`.

  Tabelle:
  - `:cells`        — `{x,y} → %Lenies.World.Cell{}` (source of truth occupazione)
  - `:lenies`       — `id    → snapshot` (scritto principalmente dai Lenies, eccezioni dal World)
  - `:child_slots`  — `slot  → record di gestazione`
  - `:history`      — ring buffer di metriche aggregate (scritto da Telemetry)
  """

  @tables [:cells, :lenies, :child_slots, :history]

  def tables, do: @tables

  def create_all do
    for t <- @tables do
      :ets.new(t, [:set, :named_table, :public, read_concurrency: true, write_concurrency: true])
    end

    :ok
  end

  def delete_all do
    for t <- @tables do
      if :ets.whereis(t) != :undefined, do: :ets.delete(t)
    end

    :ok
  end

  def clear_all do
    for t <- @tables do
      if :ets.whereis(t) != :undefined, do: :ets.delete_all_objects(t)
    end

    :ok
  end
end
