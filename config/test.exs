import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :lenies, Lenies.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "lenies_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :lenies, LeniesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Fo6xCcpuGxptUwIfHCLhhTWdOpzHH8pnUfdDMuODulRnqH5DigyaBeSOS/71Qsw+",
  server: false

# Enable the SQL sandbox plug in the endpoint (see lib/lenies_web/endpoint.ex)
config :lenies, sql_sandbox: true

# In test we don't send emails
config :lenies, Lenies.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Disable auto-start of simulation processes in test environment.
# Tests start World, LenieSupervisor, and Telemetry manually as needed.
config :lenies, auto_start_simulation: false

# Note: simulation-specific test overrides (carcass_decay: 0, initial_resource_per_cell: 0,
# initial_radiation_ticks: 0) are set in config/runtime.exs inside `if config_env() == :test`
# because runtime.exs runs AFTER config/*.exs and would otherwise overwrite them.
