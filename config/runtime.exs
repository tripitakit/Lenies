import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/lenies start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
config :lenies,
  grid_size: {256, 256},
  dashboard_throttle_ticks: 5,
  # No explicit population cap: the grid itself (grid_size cells) is the
  # hard ceiling — a Lenie can only exist in a free cell, so replication
  # back-pressures naturally once cells fill up.
  tick_interval_ms: 100,
  radiation_per_tick: 1000,
  initial_resource_per_cell: 30,
  initial_radiation_ticks: 50,
  radiation_uniform_ratio: 0.7,
  hotspot_count: 8,
  cell_resource_cap: 100,
  carcass_decay: 0.002,
  template_max_len: 8,
  template_search_radius: 256,
  eat_amount: 20,
  lenie_max_heap_size: 1_000_000,
  interpreter_steps_per_batch: 10,
  lenie_metabolize_delay_ms: 50,
  snapshot_every_batches: 10,
  call_stack_max: 32,
  codeome_length_bounds: {5, 1000},
  copy_substitution_rate: 0.005,
  copy_insert_rate: 0.0005,
  copy_delete_rate: 0.0005,
  min_viable_codeome_opcodes: 10,
  background_mutation_rate_per_1000_ticks: 1,
  defense_window_ticks: 5,
  attack_damage: 10,
  defense_attacker_penalty: 5

# In the test environment disable carcass decay so that tick_now/0 can be
# used as a GenServer-mailbox sync barrier without perturbing carcass values.
# Tests that explicitly verify decay behaviour restore the rate via
# Application.put_env inside their own setup block.
if config_env() == :test do
  config :lenies, carcass_decay: 0
  config :lenies, initial_resource_per_cell: 0
  config :lenies, initial_radiation_ticks: 0
  config :lenies, lenie_metabolize_delay_ms: 0
end

if System.get_env("PHX_SERVER") do
  config :lenies, LeniesWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing."

  config :lenies, Lenies.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :lenies, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :lenies, LeniesWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :lenies, LeniesWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :lenies, LeniesWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
