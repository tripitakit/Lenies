defmodule Lenies.Repo do
  use Ecto.Repo,
    otp_app: :lenies,
    adapter: Ecto.Adapters.Postgres
end
