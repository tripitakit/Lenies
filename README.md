# Lenies

Digital evolution sandbox built on Elixir and Phoenix LiveView. Organisms ("Lenies") live as BEAM processes that execute a bytecode "Codeome" — genome and program in one — inside a 256×256 grid world with finite, renewable resources.

The LiveView dashboard renders the world in real time and lets you:

- Spawn species from a catalog of built-in seeds or your own custom designs.
- Inspect any species: population, lineage, energy, disassembled Codeome.
- Edit a Codeome with a Scratch-style block palette (drag opcodes from the palette onto the program listing).
- Watch radiation, resource accumulation, predation, decay, and replication unfold.

## Requirements

- Elixir `~> 1.15`
- Erlang/OTP 26+
- Node.js (asset pipeline)

## Run

```bash
mix setup
mix phx.server
```

Open <http://localhost:4000>.

## Test

```bash
mix test
```

## Documentation

Design specs and implementation plans live under `docs/superpowers/`.

## License

GPL-3.0 — see [LICENSE](LICENSE).
