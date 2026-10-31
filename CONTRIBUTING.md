# Contributing

Thanks for helping. Bug reports, fixes and new FiveM adapters are all welcome.

## Before you start

- **Bugs:** open an issue with the smallest resource that shows the problem, what you expected, and what happened (include the full error and cause).
- **Large changes** (a new module, a change to the public API or the wire protocol): open an issue describing the design first. A short write-up with the problem, the proposed API and the alternatives saves everyone a rewrite.
- **Security issues:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## Working on it

```sh
lua5.4 tests/run.lua                                      # Lua unit tests
lua-language-server --check . --checklevel=Information    # Lua types
cd packages/fx && pnpm install && pnpm typecheck && pnpm test
cd packages/fx-nui && pnpm install && pnpm test
cd packages/cli && pnpm install && pnpm test
```

CI runs all of these on every pull request.

## Guidelines

- Every change comes with a test that fails without it.
- Net-facing code validates its input with a schema and never trusts the client.
- Keep the Lua and JS sides speaking the same protocol ([docs/PROTOCOL.md](docs/PROTOCOL.md)). A change to one needs the other.
- Match the surrounding code: its naming, its comment density, and LuaLS annotations for public Lua API (`types/rivo_fx.lua`).
- Add a line to [CHANGELOG.md](CHANGELOG.md) for anything users will notice.
- Public API changes update the reference page in [docs/reference](docs/reference), then `node scripts/build-docs.mjs` to regenerate `llms.txt` and `llms-full.md` (CI checks they match).

By contributing, you agree your work is released under the [MIT license](LICENSE).
