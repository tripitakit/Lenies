defmodule Lenies.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Deterministic, global codeome cache: hash → [opcode]. Owned by the
    # Application (not any individual World) so its lifetime spans the whole
    # node and is independent of World restarts. Content is invariant given
    # the hash, so sharing it across all worlds (now and future) is correct.
    if :ets.info(:species_codeomes) == :undefined do
      :ets.new(:species_codeomes, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    # Memo cache for per-species economics (size / cost / max_gain), keyed by
    # `{codeome_hash, eat_amount, attack_damage}`. `Lenies.Species.aggregate/1`
    # runs once per throttled tick per viewer; without this each call
    # re-disassembled every species' codeome. The key is invariant given the
    # hash + tuning values, so the cache is shared across all worlds/viewers
    # and stays correct when `eat_amount` / `attack_damage` are tuned.
    if :ets.info(:species_economics) == :undefined do
      :ets.new(:species_economics, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    children = [
      Lenies.Repo,
      LeniesWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lenies.PubSub},
      # Finch HTTP client — used by Swoosh's Resend adapter in prod to send
      # registration / magic-link emails. Cheap to run in dev/test too.
      {Finch, name: Lenies.Finch},
      LeniesWeb.Presence,
      {Registry, keys: :unique, name: Lenies.Registry, partitions: System.schedulers_online()},
      Lenies.Worlds.Supervisor,
      Lenies.Sandboxes,
      Lenies.Arena,
      Lenies.Snippets.Store,
      Lenies.Manual,
      LeniesWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Lenies.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LeniesWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
