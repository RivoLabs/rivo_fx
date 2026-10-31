# Changelog

All notable changes to Rivo FX. The project follows [semantic versioning](https://semver.org).

## 1.0.0

First public release.

**Core (Lua 5.4)**
- Effects with typed errors (`Fx.TaggedError`, `catchTag`), `Fx.gen` / `Fx.yield`, and method chaining.
- Fibers with structured concurrency: `fork`, `join`, `race`, `timeout`, `forEach` with a concurrency limit, and interruption that runs finalizers.
- Scopes, `acquireRelease`, Layers, Runtimes, `Fx.Schedule` retries and repeats, Ref, Deferred, Semaphore, Queue and PubSub.
- `Fx.S` schemas with refinements, transforms and LuaLS types.
- `Fx.Stream`: sources from tables, intervals, queues, PubSubs, callbacks, net events, state bags and local events, plus operators such as `groupedWithin`, `debounce`, `throttle` and `mapEffect`.
- Metrics (counters, gauges, histograms) and tracing (`withSpan`), with W3C traceparent propagation.

**FiveM**
- `Fx.net`: net events checked against a schema first, with a per-player rate limit by default.
- `Fx.rpc`: RPC with timeouts, cancellation and typed errors across the wire, plus `lib.callback` compatibility.
- Modules for security events, players, convar config, assets, scoped entities, KVP, state bags, ticks, oxmysql, NUI, and framework layers (Qbox, QBCore, ESX).
- The `rivo_fx` resource serves every resource's metrics (Prometheus) and recent spans behind a token.
- `/fxdev`: in-game devtools for live fibers, traces, failures and metrics on the server and the client, for players with the `rivo_fx.devtools` ACE.

**JS / TS**
- `@rivolabs/fx`: FiveM adapters for [Effect](https://effect.website), using the same RPC protocol as the Lua side.
- `@rivolabs/fx-nui`: typed `fetchNui` and NUI messages for pages.
- `@rivolabs/fx-cli` (`rivo-fx`): generates Lua and TypeScript schemas from one file, and resource templates.
