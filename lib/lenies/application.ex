defmodule Lenies.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Session-scoped color overrides; survives sterilize but not restart.
    if :ets.info(:species_color_overrides) == :undefined do
      :ets.new(:species_color_overrides, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])
    end

    children = [
      LeniesWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lenies, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lenies.PubSub},
      Lenies.Registry,
      Lenies.Seeds.CustomStore,
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
