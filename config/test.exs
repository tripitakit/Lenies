import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :lenies, LeniesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Fo6xCcpuGxptUwIfHCLhhTWdOpzHH8pnUfdDMuODulRnqH5DigyaBeSOS/71Qsw+",
  server: false

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

# Disable carcass decay in tests so tick_now can be used as a sync barrier
# without interfering with carcass assertions. Tests that need explicit decay
# behaviour set carcass_decay via Application.put_env in their own setup.
config :lenies, carcass_decay: 0
