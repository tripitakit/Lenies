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

    children = [
      Lenies.Repo,
      LeniesWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lenies.PubSub},
      {Registry,
       keys: :unique,
       name: Lenies.Registry,
       partitions: System.schedulers_online()},
      Lenies.Snippets.Store,
      Lenies.Manual,
      Lenies.LenieSupervisor,
      LeniesWeb.Endpoint
    ]

    children =
      if Application.get_env(:lenies, :auto_start_simulation, true) do
        children ++ [Lenies.World, Lenies.Telemetry]
      else
        children
      end

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
