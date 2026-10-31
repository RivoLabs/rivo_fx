# @rivolabs/fx

[Effect](https://effect.website) for FiveM JavaScript and TypeScript resources: validated net
events with per-player rate limits, typed RPC whose tagged errors cross the wire, a resource-level
runtime that cleans up on `onResourceStop`, convar config, a colored logger, and client asset
loaders. Built on `effect` 4 and speaks the same wire protocol as the Lua half of Rivo FX
([docs/PROTOCOL.md](../../docs/PROTOCOL.md)), so a Lua client can call a JS server RPC and the
other way round.

```sh
pnpm add @rivolabs/fx effect
```

| Import | Use it in |
|---|---|
| `@rivolabs/fx/server` | server scripts: `Net`, `Rpc`, `SecurityEvents`, `PlayerScope`, `FxServer` |
| `@rivolabs/fx/client` | client scripts: `Net`, `Rpc`, `Assets`, `Entity`, `FxClient` |
| `@rivolabs/fx` | both: `FxRuntime`, `Config`, `Logger`, the RPC error classes |

FiveM loads one plain script per file, so bundle each side (with `effect`) into a single file, for
example with esbuild `--bundle --format=iife`. The client entry uses no Node APIs.


> **Client scripts:** FiveM's client JS runtime has no `TextEncoder` or
> `TextDecoder`, and `effect` needs both when it loads. Import the polyfill
> first in every client entry, before anything that imports `effect`:
>
> ```ts
> import "@rivolabs/fx/polyfill"
> import { Effect } from "effect"
> ```

## Server

```ts
import { Effect, Layer, Schema, Stream } from "effect"
import { Config, FxRuntime, FxServer, Net, Rpc, SecurityEvents } from "@rivolabs/fx/server"

class NotEnoughMoney extends Schema.TaggedError<NotEnoughMoney>()("NotEnoughMoney", {
  balance: Schema.Number,
  wanted: Schema.Number
}) {}

const Main = Layer.effectDiscard(Effect.gen(function* () {
  const maxDeposit = yield* Config.integer("bank:maxDeposit")   // set bank:maxDeposit 5000

  // A net event. The payload is decoded before the handler runs; bad payloads and
  // floods (over 10/s per player by default) publish a SecurityEvent instead.
  yield* Net.handle("bank:deposit", Schema.Struct({ amount: Schema.Int }), (source, { amount }) =>
    Effect.gen(function* () {
      yield* Effect.log(`player ${source} deposited ${Math.min(amount, maxDeposit)}`)
      yield* Net.emitClient("bank:updated", source, amount)
    }), { rateLimit: "5/s" })

  // An RPC. NotEnoughMoney reaches the caller with its _tag and fields.
  yield* Rpc.register("bank:withdraw", { input: Schema.Struct({ amount: Schema.Int }), output: Schema.Number },
    (source, { amount }) => amount > 100
      ? Effect.fail(new NotEnoughMoney({ balance: 100, wanted: amount }))
      : Effect.succeed(100 - amount))

  // Everything a client sent that the server rejected.
  yield* SecurityEvents.stream.pipe(
    Stream.runForEach((e) => Effect.logWarning(`${e.kind} from ${e.source} on ${e.name}`)),
    Effect.forkScoped
  )
}))

// Built now, disposed on onResourceStop: handlers are removed, fibers interrupted, finalizers run.
// provideMerge (rather than provide) keeps FxServer's services available to runtime.runFork.
export const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
```

Every rejection is also sent to `TriggerEvent("rivo_fx:security", event, resourceName)`, so one
anticheat resource can watch them all. `event` is `{ kind, source, name, message? }` with `kind`
one of `invalid_payload`, `rate_limited` or `unknown_rpc`.

### Player scopes

```ts
import { PlayerScope } from "@rivolabs/fx/server"

// Interrupted when the player drops (or the resource stops).
yield* PlayerScope.fork(source, Effect.forever(Effect.sleep("1 minute").pipe(Effect.andThen(payWage(source)))))
yield* PlayerScope.addFinalizer(source, Effect.log(`saving ${source}`))
```

### Calling a client

```ts
const ok = yield* Rpc.callClient(source, "ui:confirm", { text: "Buy?" }, { output: Schema.Boolean, timeout: 5_000 })
```

## Client

```ts
import { Effect, Layer, Schema } from "effect"
import { Assets, Entity, FxClient, FxRuntime, Net, Rpc } from "@rivolabs/fx/client"

const Main = Layer.effectDiscard(Effect.gen(function* () {
  yield* Net.handle("bank:updated", Schema.Number, (balance) => Effect.log(`balance ${balance}`))

  yield* Rpc.register("ui:confirm", { input: Schema.Struct({ text: Schema.String }) }, ({ text }) =>
    Effect.succeed(text.length > 0))
}))

const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxClient.layer)))

const withdraw = Rpc.call("bank:withdraw", { amount: 500 }, { output: Schema.Number, timeout: 5_000 }).pipe(
  Effect.catchTag("NotEnoughMoney", (e) => Effect.succeed(e.balance as number)),
  Effect.catchTag("RpcTimeout", () => Effect.succeed(0))
)

const spawnCar = Effect.scoped(Effect.gen(function* () {
  const hash = yield* Assets.modelScoped("adder", { timeout: 5_000 })   // SetModelAsNoLongerNeeded on release
  const [x, y, z] = GetEntityCoords(PlayerPedId(), true) as [number, number, number]
  return CreateVehicle(hash, x, y, z, 0, true, false)
}))

runtime.runFork(Effect.andThen(withdraw, spawnCar))
```

`Rpc.call` fails with the host's error rebuilt as a `RemoteError` with the same `_tag` and fields
(so `catchTag` works), or with your own class when you pass `errors: NotEnoughMoney` (or a
`Schema.Union` of error classes). It can also fail with `RpcTimeout`, `RpcNotFound`,
`RpcInvalidInput`, `RpcRateLimited`, `RpcInternalError` or `RpcInvalidOutput`. Interrupting the
call, including by its timeout, sends the cancel event and the host interrupts its handler.
Defects never cross the wire: they arrive as `RpcInternalError`.

Assets: `Assets.model`, `Assets.animDict` and `Assets.ptfxAsset` (typed `InvalidModel`,
`InvalidAnimDict` and `AssetTimeout` errors), each with a `...Scoped` variant that releases the
asset when its scope closes. Entities: `Entity.requestControl(entity, { timeout })` and
`Entity.fromNetId(netId, { timeout })` fail with `EntityNotFound` or `EntityTimeout`.

## Config and logging

`Config.layer()` (part of `FxServer.layer` and `FxClient.layer`) installs a `ConfigProvider` that
reads convars with `GetConvar`. Any Effect `Config` works. Nested paths join with `:`:

```ts
import { Config as EffectConfig } from "effect"

const max = yield* Config.integer("my_max")                                   // set my_max 32
const debug = yield* EffectConfig.Boolean("debug").pipe(EffectConfig.nested("my_res"))  // my_res:debug
```

`Logger.layer` prints `Effect.log*` lines through the FiveM console with color codes (`^1` errors,
`^3` warnings, `^5` info). It reads the minimum level from `set rivo_fx:logLevel Debug`.

## Example and tests

[examples/js_example](../../examples/js_example) is a full resource. `node build.mjs` bundles it
after `pnpm build`.

```sh
pnpm typecheck
pnpm build
pnpm test
```
