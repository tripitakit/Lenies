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
  # Population is bounded by two mechanisms (see :spawn_cap / :replication_cap
  # at the bottom of this block): explicit per-world caps are the primary
  # safety net for sandboxes on a small VPS, and grid_size cells act as a
  # secondary hard ceiling — a Lenie can only exist in a free cell, so
  # replication also back-pressures naturally once cells fill up.
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
  defense_attacker_penalty: 5,
  spawn_cap: 10,
  replication_cap: 50

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

  # Set ECTO_IPV6=true if Postgres is reachable only on IPv6 (e.g. a remote
  # IPv6-only DB host). For a local Postgres on the same VPS this stays off.
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :lenies, Lenies.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

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

  # Persistent snapshot root. If LENIES_SNAPSHOT_ROOT is set (as in the systemd
  # env file pointing at /var/lib/lenies/snapshots), use it. Otherwise the
  # default Lenies.Snapshot.snapshot_root/0 picks <tmp>/lenies-snapshots/,
  # which won't survive a reboot.
  if snapshot_root = System.get_env("LENIES_SNAPSHOT_ROOT") do
    config :lenies, :snapshot_root, snapshot_root
  end

  config :lenies, LeniesWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind on IPv6 loopback only — the app is exclusively reached through
      # nginx on the same host, so listening on public interfaces would only
      # widen the attack surface. nginx proxy_pass uses http://localhost:PORT.
      # If you ever need direct external access (e.g. debugging without
      # nginx), temporarily switch to {0, 0, 0, 0, 0, 0, 0, 0}.
      ip: {0, 0, 0, 0, 0, 0, 0, 1},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## Mailer — Resend transactional email service
  #
  # The free Resend tier (3000 emails/month) covers a small public community
  # with room to spare. The sending domain must be verified via DNS (SPF +
  # DKIM CNAME) in the Resend dashboard before the API key works.
  #
  # If you ever migrate to another provider (Postmark, SES, SMTP, etc.) the
  # only change is the `adapter:` line plus credentials env vars — the rest
  # of the app does not care which SMTP transport delivers the email.
  resend_api_key =
    System.get_env("RESEND_API_KEY") ||
      raise """
      environment variable RESEND_API_KEY is missing.
      Generate one at https://resend.com/api-keys after verifying the sending
      domain in the Resend dashboard. See DEPLOY.md Phase 0 for details.
      """

  config :lenies, Lenies.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: resend_api_key

  config :lenies, :mailer_from,
    name: System.get_env("MAILER_FROM_NAME") || "Lenies",
    address: System.get_env("MAILER_FROM_ADDRESS") || "noreply@#{host}"

  # Swoosh sends through an HTTP API in prod. Enable the Finch-based API
  # client; the Lenies.Finch process is started in Lenies.Application.
  config :swoosh, :api_client, Swoosh.ApiClient.Finch
  config :swoosh, :finch_name, Lenies.Finch

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
