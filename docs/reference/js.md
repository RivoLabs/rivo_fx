# JS and TypeScript: @rivolabs/fx

`@rivolabs/fx` brings Rivo FX to FiveM JavaScript and TypeScript resources, built on the real
[`effect`](https://effect.website) package (version 4). It gives you validated net events with
per-player rate limits, typed RPC whose tagged errors cross the wire, a runtime that cleans up on
`onResourceStop`, player scopes, convar config, a FiveM console logger, and client asset and entity
helpers. It speaks the same wire protocol as the Lua library ([PROTOCOL.md](../PROTOCOL.md)), so a
Lua client can call a TypeScript server RPC and the other way round.

## Install

```sh
pnpm add @rivolabs/fx effect     # or: npm install @rivolabs/fx effect
```

- `effect` is a peer dependency: `^4.1.0`. The package is built and tested against `effect` 4.1.0.
- FiveM loads one plain script per file, so you bundle each side, with `effect`, into a single file.
  See [Bundling a resource](#bundling-a-resource).

## Entry points

| Import | Use it in | Exports |
|---|---|---|
| `@rivolabs/fx/server` | server scripts | everything in `@rivolabs/fx`, plus `FxServer`, `Net`, `Rpc`, `RpcServer`, `PlayerScope`, `PlayerScopes`, `RateLimiter`, `SecurityEvents`, type `SecurityEvent` |
| `@rivolabs/fx/client` | client scripts | everything in `@rivolabs/fx`, plus `FxClient`, `Net`, `Rpc`, `RpcClient`, `Assets`, `Entity` |
| `@rivolabs/fx` | code shared by both sides | `FxRuntime`, `Config`, `Logger`, `Protocol`, the RPC error classes, `RemoteError`, rate-limit helpers, RPC engine types |
| `@rivolabs/fx/polyfill` | first line of every client entry | nothing; installs `TextEncoder` and `TextDecoder` |

`Net` and `Rpc` exist on both sides with different signatures. Always import them from the side
you are on.

### Why the polyfill exists

FiveM's client JS runtime has no `TextEncoder` or `TextDecoder`. `effect` creates both when its
modules load, so a client bundle without them fails at startup with
`TextEncoder is not defined`. `@rivolabs/fx/polyfill` installs small UTF-8 versions on
`globalThis`, and does nothing where the globals already exist (server, browser, Node).

It must run before any module that imports `effect`. ES imports are evaluated in order, and the
built `@rivolabs/fx/client` file itself starts with `import ... from "effect"`, so it cannot fix
this on its own. Import the polyfill first, by itself:

```ts
import "@rivolabs/fx/polyfill"          // first, before anything that imports effect
import { Effect, Layer } from "effect"
import { FxClient, FxRuntime } from "@rivolabs/fx/client"
```

Server entries do not need it.

## A complete resource

```ts
// src/server.ts
import { Effect, Layer, Schema, Stream } from "effect"
import { Config, FxRuntime, FxServer, Net, Rpc, SecurityEvents } from "@rivolabs/fx/server"

class NotEnoughMoney extends Schema.TaggedError<NotEnoughMoney>()("NotEnoughMoney", {
  balance: Schema.Number,
  wanted: Schema.Number
}) {}

const Main = Layer.effectDiscard(Effect.gen(function* () {
  const maxDeposit = yield* Config.integer("bank:maxDeposit")    // set bank:maxDeposit 5000

  yield* Net.handle("bank:deposit", Schema.Struct({ amount: Schema.Int }), (source, { amount }) =>
    Effect.gen(function* () {
      yield* Effect.log(`player ${source} deposited ${Math.min(amount, maxDeposit)}`)
      yield* Net.emitClient("bank:updated", source, amount)
    }), { rateLimit: "5/s" })

  yield* Rpc.register("bank:withdraw",
    { input: Schema.Struct({ amount: Schema.Int }), output: Schema.Number },
    (source, { amount }) => amount > 100
      ? Effect.fail(new NotEnoughMoney({ balance: 100, wanted: amount }))
      : Effect.succeed(100 - amount))

  yield* SecurityEvents.stream.pipe(
    Stream.runForEach((e) => Effect.logWarning(`${e.kind} from ${e.source} on ${e.name}`)),
    Effect.forkScoped
  )
}))

export const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
```

```ts
// src/client.ts
import "@rivolabs/fx/polyfill"
import { Effect, Layer, Schema } from "effect"
import { FxClient, FxRuntime, Net, Rpc } from "@rivolabs/fx/client"

const Main = Layer.effectDiscard(Effect.gen(function* () {
  yield* Net.handle("bank:updated", Schema.Number, (amount) => Effect.log(`deposited ${amount}`))
}))

const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxClient.layer)))

RegisterCommand("withdraw", () => {
  runtime.runFork(
    Rpc.call("bank:withdraw", { amount: 500 }, { output: Schema.Number, timeout: 5_000 }).pipe(
      Effect.flatMap((left) => Effect.log(`balance ${left}`)),
      Effect.catchTag("NotEnoughMoney", (e) => Effect.log(`only ${String(e["balance"])} left`)),
      Effect.catchTag("RpcTimeout", () => Effect.log("the bank did not answer"))
    )
  )
}, false)
```

Everything registered inside `Main` lives in the runtime's scope. When the resource stops, the
runtime is disposed: listeners are removed, fibers are interrupted and finalizers run, inside the
`onResourceStop` handler.

## Runtime

### FxRuntime.make(layer, options?)

```ts
export const make: <R, E>(layer: Layer.Layer<R, E, never>, options?: FxRuntimeOptions) => FxRuntime<R, E>

export interface FxRuntime<R, E> extends ManagedRuntime.ManagedRuntime<R, E> {
  readonly stop: () => void
}
export interface FxRuntimeOptions {
  readonly resource?: string
}
```

- Parameters:
  - `layer`: a fully provided layer (no requirements left). Usually `Main.pipe(Layer.provideMerge(FxServer.layer))`.
  - `options.resource`: the resource whose `onResourceStop` disposes the runtime. Defaults to `GetCurrentResourceName()`.
- Returns: a `ManagedRuntime` with an extra `stop()` that disposes it now and flushes pending work synchronously.
- Fails with: nothing synchronously. If the layer fails to build, the cause is printed with `console.error` as `[rivo_fx] failed to start the runtime:` followed by the pretty cause.
- Notes:
  - The layer starts building immediately and as far as it can without waiting, so net handlers and RPCs are registered before your script finishes loading.
  - It uses a `FlushableScheduler`, so disposal can run every finalizer inside `onResourceStop`, before FiveM tears the JS context down.
  - Use `Layer.provideMerge(FxServer.layer)` rather than `Layer.provide` when you want to call `runtime.runFork(...)` with effects that need `Rpc`, `Net` and so on. `provide` hides those services from the runtime's output.
  - `stop()` is idempotent and removes the `onResourceStop` listener.
- Example:

```ts
const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
runtime.runFork(Net.broadcast("shop:reopened"))
```

### FxRuntime.FlushableScheduler

```ts
export class FlushableScheduler implements Scheduler.Scheduler {
  readonly executionMode: "async"
  shouldYield(fiber: Parameters<Scheduler.Scheduler["shouldYield"]>[0]): boolean
  makeDispatcher(): Scheduler.SchedulerDispatcher
  flush(): void
}
```

- Notes: the scheduler `FxRuntime.make` installs. All fibers share one dispatcher, and `flush()` runs every queued task, including tasks queued while flushing. You only need it if you build your own `ManagedRuntime`.

### FxServer.layer

```ts
export type Services = SecurityEvents | RateLimiter | RpcServer | PlayerScopes
export const layer: Layer.Layer<Services>
```

- Returns: one layer with `SecurityEvents`, `RateLimiter`, `RpcServer` (RPC host and caller), `PlayerScopes`, the convar `ConfigProvider` from `Config.layer()` and the FiveM logger from `Logger.layer`.
- Notes: provide it to your main layer with `Layer.provideMerge`. It needs `@rivolabs/fx/server` (server typings).
- Example:

```ts
export const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
```

### FxClient.layer

```ts
export type Services = RpcClient
export const layer: Layer.Layer<Services>
```

- Returns: `RpcClient` (RPC caller and host), the convar `ConfigProvider` and the FiveM logger.
- Example:

```ts
const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxClient.layer)))
```

## Server: net events

### Net.handle(name, schema, handler, options?) (server)

```ts
export const handle: <S extends Schema.Decoder<unknown>, R = never>(
  name: string,
  schema: S,
  handler: (source: number, input: S["Type"]) => Effect.Effect<unknown, unknown, R>,
  options?: HandleOptions
) => Effect.Effect<void, never, SecurityEvents | RateLimiter | Scope.Scope | R>

export interface HandleOptions {
  readonly rateLimit?: RateLimit | false | undefined
}
```

- Parameters:
  - `name`: the FiveM net event name.
  - `schema`: an Effect schema for the single payload argument.
  - `handler`: runs with the player id and the decoded payload.
  - `options.rateLimit`: `"<n>/s"`, `"<n>/m"` or `"<n>/h"`. Defaults to `"10/s"` per player. `false` disables it.
- Returns: an effect that registers the listener for the lifetime of the current `Scope`.
- Fails with: never. Rejections are published as `SecurityEvent`s:
  - over the limit: `rate_limited` (logged at Debug level), handler not run;
  - payload fails the schema: `invalid_payload` with the schema message (logged as a warning), handler not run.
- Notes:
  - The event carries exactly one argument, the payload. Clients send `TriggerServerEvent(name, payload)`. Extra positional arguments are ignored, so send an object.
  - Events with no player source (a server-side `TriggerEvent`) are ignored.
  - The rate limit is checked before the schema. Each (player, event) pair has its own token bucket, and buckets are forgotten when the player drops.
  - Each call runs on its own fiber. A handler failure or defect is logged with `Effect.logError` as `net event "<name>" failed`. The handler is interrupted if the player drops, and when the registering scope closes.
- Example:

```ts
yield* Net.handle("shop:buy", Schema.Struct({ item: Schema.String, qty: Schema.Int }), (source, { item, qty }) =>
  Effect.log(`${source} bought ${qty}x ${item}`), { rateLimit: "5/s" })
```

### Net.emitClient(name, player, payload?)

```ts
export const emitClient: (name: string, player: number, payload?: unknown) => Effect.Effect<void>
```

- Parameters: event name, target player id (`-1` for everyone), one payload.
- Returns: an effect that calls `TriggerClientEvent(name, player, payload)`.
- Example:

```ts
yield* Net.emitClient("bank:updated", source, { balance: 250 })
```

### Net.broadcast(name, payload?)

```ts
export const broadcast: (name: string, payload?: unknown) => Effect.Effect<void>
```

- Returns: an effect that calls `TriggerClientEvent(name, -1, payload)`.
- Example:

```ts
yield* Net.broadcast("weather:changed", { type: "RAIN" })
```

## Server: RPC

### Rpc.register(name, options, handler) (server)

```ts
export const register: <I extends Schema.Decoder<unknown>, A, E, R = never>(
  name: string,
  options: RegisterOptions<I, A>,
  handler: (source: number, input: I["Type"]) => Effect.Effect<A, E, R>
) => Effect.Effect<void, never, RpcServer | RateLimiter | Scope.Scope | R>

export interface RegisterOptions<I extends Schema.Decoder<unknown>, A> {
  readonly input: I
  readonly output?: Schema.Codec<A, unknown> | undefined
  readonly rateLimit?: RateLimit | false | undefined
}
```

- Parameters:
  - `name`: the RPC name callers use.
  - `options.input`: required schema for the request input. Use `Schema.Unknown` to accept anything on purpose.
  - `options.output`: optional codec. The handler's value is encoded with it before it is sent.
  - `options.rateLimit`: per-player token bucket, default `"10/s"`, `false` to disable. RPC buckets are separate from net event buckets with the same name.
  - `handler`: gets the player id and the decoded input.
- Returns: an effect that registers the handler for the lifetime of the current `Scope`. Registering the same name again replaces the earlier handler.
- Fails with (sent to the caller, see [Errors](#error-classes)):
  - `RpcNotFound` when no handler has that name (publishes `unknown_rpc`, not rate limited);
  - `RpcRateLimited` over the limit (publishes `rate_limited`);
  - `RpcInvalidInput` when the input fails `options.input` (publishes `invalid_payload`);
  - the handler's own tagged error, with its `_tag` and fields;
  - `RpcInternalError` for a defect, a failure without a `_tag`, a tagged failure that comes with a defect, or an output that fails to encode.
- Notes:
  - Requests are processed in this order: envelope, name, rate limit, input. A malformed envelope gets no reply and publishes `invalid_payload` named `__rfx:<resource>:req`.
  - The handler runs in a span `rpc.server <name>` that continues the caller's trace (see [Tracing](#tracing)).
  - If the caller cancels (its timeout fired or its fiber was interrupted) or the player drops, the handler fiber is interrupted and no response is sent.
  - Defects are logged on the server with `Effect.logError` as `RPC "<name>" died`. Their details never reach the client.
- Example:

```ts
class OutOfStock extends Schema.TaggedError<OutOfStock>()("OutOfStock", { item: Schema.String }) {}

yield* Rpc.register("shop:buy",
  { input: Schema.Struct({ item: Schema.String }), output: Schema.Struct({ item: Schema.String }) },
  (source, { item }) => item === "phone"
    ? Effect.fail(new OutOfStock({ item }))
    : Effect.succeed({ item }))
```

### Rpc.callClient(player, name, input, options?)

```ts
export const callClient: <A = unknown, E = never>(
  player: number,
  name: string,
  input: unknown,
  options?: CallClientOptions<A, E>
) => Effect.Effect<A, E | RpcError | RemoteError, RpcServer>

export interface CallClientOptions<A, E> extends Omit<CallOptions, "output" | "errors"> {
  readonly output?: Schema.Decoder<A> | undefined
  readonly errors?: Schema.Decoder<E> | undefined
}
// inherited from CallOptions:
//   readonly resource?: string | undefined   resource hosting the RPC, default: this resource
//   readonly timeout?: number | undefined    milliseconds, default 10 000
```

- Parameters: the player id, the RPC name registered on that player's client, the input, and options.
- Returns: the client's value, decoded with `output` when given.
- Fails with: `RpcTimeout`, `RpcNotFound`, `RpcInvalidInput`, `RpcInternalError`, `RpcInvalidOutput`, your class when `errors` decodes the tag, or `RemoteError` for any other tag. Client hosts have no rate limit, so `RpcRateLimited` only comes from a server host.
- Notes: a response is matched on (player, id), so only the player you called can answer. Interrupting the call, including by its timeout, sends the cancel event and the client interrupts its handler.
- Example:

```ts
const ok = yield* Rpc.callClient(source, "ui:confirm", { text: "Buy?" }, { output: Schema.Boolean, timeout: 5_000 })
```

### RpcServer

```ts
export class RpcServer extends Context.Service<RpcServer, {
  readonly host: Host<number>
  readonly caller: Caller<number>
}>()("@rivolabs/fx/RpcServer") {
  static readonly layer: Layer.Layer<RpcServer, never, SecurityEvents>
}
```

- Notes: the service behind `Rpc.register` and `Rpc.callClient`. Part of `FxServer.layer`. It listens on `__rfx:<resource>:req`, `:cancel` and `:res`. `Rpc.serverTransport` (a `Transport<number>`) is exported for building your own host or caller.

## Server: player scopes

One `Scope` per connected player, created on first use and closed on `playerDropped` (and when the
runtime is disposed). Put per-player work and cleanup in it.

### PlayerScope.get(player)

```ts
export const get: (player: number) => Effect.Effect<Scope.Scope, never, PlayerScopes>
```

- Returns: the player's scope, created on first use.
- Example:

```ts
const scope = yield* PlayerScope.get(source)
```

### PlayerScope.fork(player, effect)

```ts
export const fork: <A, E, R>(player: number, effect: Effect.Effect<A, E, R>) =>
  Effect.Effect<Fiber.Fiber<A, E>, never, PlayerScopes | R>
```

- Returns: the fiber, forked into the player's scope. It is interrupted when the player drops.
- Example:

```ts
yield* PlayerScope.fork(source, Effect.forever(Effect.sleep("1 minute").pipe(Effect.andThen(Effect.log(`pay ${source}`)))))
```

### PlayerScope.addFinalizer(player, finalizer)

```ts
export const addFinalizer: <R>(player: number, finalizer: Effect.Effect<void, never, R>) =>
  Effect.Effect<void, never, PlayerScopes | R>
```

- Notes: `finalizer` runs when the player drops or the runtime is disposed. Services it needs are captured when you call `addFinalizer`.
- Example:

```ts
yield* PlayerScope.addFinalizer(source, Effect.log(`saving ${source}`))
```

### PlayerScope.scoped(player, effect)

```ts
export const scoped: <A, E, R>(player: number, effect: Effect.Effect<A, E, R>) =>
  Effect.Effect<A, E, PlayerScopes | Exclude<R, Scope.Scope>>
```

- Returns: the result of `effect`, run with the player's scope as its `Scope`. Anything it acquires with `Effect.acquireRelease` is released when the player drops.
- Example:

```ts
const vehicle = yield* PlayerScope.scoped(source, Effect.acquireRelease(
  Effect.sync(() => CreateVehicle(GetHashKey("adder"), 0, 0, 72, 0, true, true)),
  (veh) => Effect.sync(() => DeleteEntity(veh))
))
```

### PlayerScopes

```ts
export class PlayerScopes extends Context.Service<PlayerScopes, {
  readonly scope: (player: number) => Effect.Effect<Scope.Scope>
}>()("@rivolabs/fx/PlayerScopes") {
  static readonly layer: Layer.Layer<PlayerScopes>
}
```

- Notes: the service behind `PlayerScope.*`. Part of `FxServer.layer`. Also exported as `PlayerScope.PlayerScopes`.

## Server: rate limiting and security events

### RateLimiter

```ts
export class RateLimiter extends Context.Service<RateLimiter, {
  readonly buckets: (kind: "net" | "rpc", name: string, limit: RateLimit) => TokenBuckets
}>()("@rivolabs/fx/RateLimiter") {
  static readonly layer: Layer.Layer<RateLimiter>
}
```

- Notes: owns the token buckets used by `Net.handle` and `Rpc.register`. One bucket set per (kind, name, limit). Keys inside a set are `"<player>|<name>"`. A player's buckets are deleted on `playerDropped`. Part of `FxServer.layer`.
- Fails with: `buckets` throws `Invalid rate limit "<limit>": expected "<n>/s", "<n>/m" or "<n>/h" with n > 0` for a malformed limit. Inside `Net.handle` or `Rpc.register` that becomes a defect and the layer fails to build.

### SecurityEvent

```ts
export interface SecurityEvent {
  readonly kind: "invalid_payload" | "rate_limited" | "unknown_rpc"
  readonly source: number
  readonly name: string
  readonly message?: string | undefined
}
```

- Notes: something a client sent that the server rejected. `source` is the player id, `name` the event or RPC name. The Lua library adds a fourth kind, `invalid_state`, and a `resource` field; the JS package has neither.

### SecurityEvents.publish(event)

```ts
export const publish: (event: SecurityEvent) => Effect.Effect<void, never, SecurityEvents>
```

- Notes: logs the event (`rate_limited` at Debug, the others as warnings), publishes it inside the resource, and fires `emit("rivo_fx:security", event, resourceName)` so one anticheat resource can watch every resource. Use it to report your own rejections.
- Example:

```ts
yield* SecurityEvents.publish({ kind: "invalid_payload", source, name: "shop:buy", message: "price mismatch" })
```

### SecurityEvents.subscribe

```ts
export const subscribe: Effect.Effect<PubSub.Subscription<SecurityEvent>, never, SecurityEvents | Scope.Scope>
```

- Returns: a subscription for the lifetime of the current scope. Events published before subscribing are not seen.

### SecurityEvents.stream

```ts
export const stream: Stream.Stream<SecurityEvent, never, SecurityEvents>
```

- Returns: every security event from when the stream starts.
- Example:

```ts
yield* SecurityEvents.stream.pipe(
  Stream.filter((e) => e.kind !== "rate_limited"),
  Stream.runForEach((e) => Effect.logWarning(`${e.kind} from ${e.source} on ${e.name}`)),
  Effect.forkScoped
)
```

### SecurityEvents.SecurityEvents

```ts
export class SecurityEvents extends Context.Service<SecurityEvents, {
  readonly publish: (event: SecurityEvent) => Effect.Effect<void>
  readonly subscribe: Effect.Effect<PubSub.Subscription<SecurityEvent>, never, Scope.Scope>
  readonly stream: Stream.Stream<SecurityEvent>
}>()("@rivolabs/fx/SecurityEvents") {
  static readonly layer: Layer.Layer<SecurityEvents>
}
```

- Notes: the service class. From `@rivolabs/fx/server`, `SecurityEvents` is the module namespace, so the class is `SecurityEvents.SecurityEvents`. Part of `FxServer.layer`.

## Client: net events

### Net.handle(name, schema, handler) (client)

```ts
export const handle: <S extends Schema.Decoder<unknown>, R = never>(
  name: string,
  schema: S,
  handler: (input: S["Type"]) => Effect.Effect<unknown, unknown, R>
) => Effect.Effect<void, never, Scope.Scope | R>
```

- Parameters: event name, payload schema, handler (no source: it is always the server).
- Returns: an effect that registers the listener for the lifetime of the current scope.
- Fails with: never. An invalid payload is logged as a warning (`net event "<name>": invalid payload`) and the handler does not run. A handler failure is logged as `net event "<name>" failed`.
- Notes: no rate limit on the client.
- Example:

```ts
yield* Net.handle("bank:updated", Schema.Struct({ balance: Schema.Number }), ({ balance }) =>
  Effect.log(`balance ${balance}`))
```

### Net.emitServer(name, payload?)

```ts
export const emitServer: (name: string, payload?: unknown) => Effect.Effect<void>
```

- Returns: an effect that calls `TriggerServerEvent(name, payload)`.
- Example:

```ts
yield* Net.emitServer("shop:buy", { item: "water", qty: 2 })
```

## Client: RPC

### Rpc.call(name, input, options?)

```ts
export const call: <A = unknown, E = never>(
  name: string,
  input: unknown,
  options?: ClientCallOptions<A, E>
) => Effect.Effect<A, E | RpcError | RemoteError, RpcClient>

export interface ClientCallOptions<A, E> extends Omit<CallOptions, "output" | "errors"> {
  readonly output?: Schema.Decoder<A> | undefined
  readonly errors?: Schema.Decoder<E> | undefined
}
// inherited from CallOptions:
//   readonly resource?: string | undefined   resource hosting the RPC, default: this resource
//   readonly timeout?: number | undefined    milliseconds, default 10 000
```

- Parameters:
  - `name`, `input`: the RPC and its input. Send one value (usually an object).
  - `options.output`: validates the response. A mismatch fails with `RpcInvalidOutput`.
  - `options.errors`: decodes known error tags into your own classes, for example `NotEnoughMoney` or a `Schema.Union([A, B])` of `Schema.TaggedError` classes.
  - `options.resource`: the resource hosting the RPC. Set it when calling another resource.
  - `options.timeout`: milliseconds before `RpcTimeout`, default 10 000.
- Returns: the server's value.
- Fails with:
  - `RpcTimeout` (local), `RpcInvalidOutput` (local), `RpcNotFound`, `RpcInvalidInput`, `RpcRateLimited`, `RpcInternalError`, rebuilt as their real classes;
  - your class, when `errors` decodes the tag;
  - otherwise `RemoteError` with the same `_tag` and fields, so `Effect.catchTag("NotEnoughMoney", ...)` works.
- Notes:
  - The call runs in a span `rpc.client <name>` and sends its traceparent. Interrupting the call, including by its timeout, sends `__rfx:<target>:cancel` and the server interrupts its handler.
  - The error type always includes `RemoteError`, whose `_tag` is typed `string`. So even with `errors: NotEnoughMoney`, `Effect.catchTag("NotEnoughMoney", (e) => ...)` types `e` as `NotEnoughMoney | RemoteError`. At runtime it is your class; narrow with `instanceof` to read typed fields.
- Example:

```ts
class NotEnoughMoney extends Schema.TaggedError<NotEnoughMoney>()("NotEnoughMoney", {
  balance: Schema.Number,
  wanted: Schema.Number
}) {}

const left = yield* Rpc.call("bank:withdraw", { amount: 50 }, { output: Schema.Number, errors: NotEnoughMoney }).pipe(
  Effect.catchTag("NotEnoughMoney", (e) => Effect.succeed(e instanceof NotEnoughMoney ? e.balance : 0))
)
```

### Rpc.register(name, options, handler) (client)

```ts
export const register: <I extends Schema.Decoder<unknown>, A, E, R = never>(
  name: string,
  options: RegisterOptions<I, A>,
  handler: (input: I["Type"]) => Effect.Effect<A, E, R>
) => Effect.Effect<void, never, RpcClient | Scope.Scope | R>

export interface RegisterOptions<I extends Schema.Decoder<unknown>, A> {
  readonly input: I
  readonly output?: Schema.Codec<A, unknown> | undefined
}
```

- Parameters: RPC name, input schema (required), optional output codec, handler (no source).
- Returns: an effect that registers a server → client RPC for the lifetime of the current scope.
- Fails with (sent to the server): `RpcNotFound`, `RpcInvalidInput`, the handler's tagged error, or `RpcInternalError`.
- Notes: no rate limit and no security events on the client.
- Example:

```ts
yield* Rpc.register("ui:confirm", { input: Schema.Struct({ text: Schema.String }), output: Schema.Boolean },
  ({ text }) => Effect.succeed(text.length > 0))
```

### RpcClient

```ts
export type Server = "server"
export class RpcClient extends Context.Service<RpcClient, {
  readonly host: Host<Server>
  readonly caller: Caller<Server>
}>()("@rivolabs/fx/RpcClient") {
  static readonly layer: Layer.Layer<RpcClient>
}
```

- Notes: the service behind client `Rpc.call` and `Rpc.register`. Part of `FxClient.layer`. `Rpc.clientTransport` (a `Transport<"server">`) is exported too.

## Client: assets

```ts
export interface LoadOptions {
  readonly timeout?: number | undefined    // ms before AssetTimeout, default 10 000
  readonly interval?: number | undefined   // ms between HasXLoaded checks, default 0 (every tick)
}
```

### Assets.model(model, options?)

```ts
export const model: (model: string | number, options?: LoadOptions) => Effect.Effect<number, InvalidModel | AssetTimeout>
```

- Parameters: a model name (hashed with `GetHashKey`) or hash, and load options.
- Returns: the model hash once `HasModelLoaded` is true.
- Fails with: `InvalidModel { model }` when `IsModelInCdimage` or `IsModelValid` is false; `AssetTimeout { kind: "model", asset, timeoutMs }`.
- Notes: a request that times out is released with `SetModelAsNoLongerNeeded`. The model stays loaded on success; use `modelScoped` to release it.
- Example:

```ts
const hash = yield* Assets.model("adder", { timeout: 5_000 })
```

### Assets.modelScoped(name, options?)

```ts
export const modelScoped: (name: string | number, options?: LoadOptions) =>
  Effect.Effect<number, InvalidModel | AssetTimeout, Scope.Scope>
```

- Notes: `Assets.model`, released with `SetModelAsNoLongerNeeded` when the scope closes.
- Example:

```ts
const veh = yield* Effect.scoped(Effect.gen(function* () {
  const hash = yield* Assets.modelScoped("adder", { timeout: 5_000 })
  const [x, y, z] = GetEntityCoords(PlayerPedId(), true) as [number, number, number]
  return CreateVehicle(hash, x, y, z, 0, true, false)
}))
```

### Assets.animDict(dict, options?)

```ts
export const animDict: (dict: string, options?: LoadOptions) => Effect.Effect<string, InvalidAnimDict | AssetTimeout>
```

- Fails with: `InvalidAnimDict { animDict }` when `DoesAnimDictExist` is false; `AssetTimeout { kind: "animDict", ... }`.
- Example:

```ts
const dict = yield* Assets.animDict("missfbi1", { timeout: 3_000 })
```

### Assets.animDictScoped(dict, options?)

```ts
export const animDictScoped: (dict: string, options?: LoadOptions) =>
  Effect.Effect<string, InvalidAnimDict | AssetTimeout, Scope.Scope>
```

- Notes: released with `RemoveAnimDict` when the scope closes.

### Assets.ptfxAsset(asset, options?)

```ts
export const ptfxAsset: (asset: string, options?: LoadOptions) => Effect.Effect<string, AssetTimeout>
```

- Fails with: `AssetTimeout { kind: "ptfxAsset", ... }`. There is no existence check.
- Example:

```ts
yield* Assets.ptfxAsset("core")
```

### Assets.ptfxAssetScoped(asset, options?)

```ts
export const ptfxAssetScoped: (asset: string, options?: LoadOptions) => Effect.Effect<string, AssetTimeout, Scope.Scope>
```

- Notes: released with `RemoveNamedPtfxAsset` when the scope closes.

## Client: entities

```ts
export interface WaitOptions {
  readonly timeout?: number | undefined    // ms before EntityTimeout, default 5 000
  readonly interval?: number | undefined   // ms between checks, default 0 (every tick)
}
```

### Entity.requestControl(entity, options?)

```ts
export const requestControl: (entity: number, options?: WaitOptions) => Effect.Effect<number, EntityNotFound | EntityTimeout>
```

- Returns: the entity, once `NetworkHasControlOfEntity` is true. It calls `NetworkRequestControlOfEntity` on every check.
- Fails with: `EntityNotFound { entity }` when the handle does not exist; `EntityTimeout { operation: "requestControl", id, timeoutMs }`.
- Example:

```ts
const veh = yield* Entity.requestControl(GetVehiclePedIsIn(PlayerPedId(), false), { timeout: 2_000 })
```

### Entity.fromNetId(netId, options?)

```ts
export const fromNetId: (netId: number, options?: WaitOptions) => Effect.Effect<number, EntityTimeout>
```

- Returns: the local entity handle once the network id exists on this client.
- Fails with: `EntityTimeout { operation: "fromNetId", id, timeoutMs }`.
- Example:

```ts
const veh = yield* Entity.fromNetId(netId, { timeout: 5_000 })
```

## Shared: config

### Config.layer(options?)

```ts
export const layer: (options?: ConvarProviderOptions) => Layer.Layer<never>
export interface ConvarProviderOptions {
  readonly separator?: string   // joins nested config paths, default ":"
}
```

- Returns: a layer that replaces the active `ConfigProvider` with `Config.convarProvider(options)`. Already part of `FxServer.layer` and `FxClient.layer`.
- Notes: any Effect `Config` then reads convars. Nested paths join with the separator: `Config.Boolean("debug").pipe(Config.nested("my_res"))` reads `my_res:debug`.
- Example:

```ts
import { Config as EffectConfig } from "effect"

const debug = yield* EffectConfig.Boolean("debug").pipe(EffectConfig.nested("my_res"))   // set my_res:debug true
```

### Config.convarProvider(options?)

```ts
export const convarProvider: (options?: ConvarProviderOptions) => ConfigProvider.ConfigProvider
```

- Notes: an Effect `ConfigProvider` backed by `GetConvar`. An unset convar is "missing", so `Config.withDefault` and `Config.option` work. A convar set to an empty string is the value `""`, not missing (the Lua `Fx.config` treats `""` as unset).

### Config.integer(name)

```ts
export const integer: (name: string) => Config.Config<number>
```

- Returns: Effect's `Config.Int(name)`. Read it with `yield*`.
- Fails with: Effect's `ConfigError` (`_tag: "ConfigError"`) when the convar is unset or does not parse.
- Example:

```ts
const max = yield* Config.integer("my_max")   // set my_max 32
```

### Config.number(name)

```ts
export const number: (name: string) => Config.Config<number>
```

- Returns: Effect's `Config.Number(name)`.

### Config.string(name)

```ts
export const string: (name: string) => Config.Config<string>
```

- Returns: Effect's `Config.String(name)`.

### Config.boolean(name)

```ts
export const boolean: (name: string) => Config.Config<boolean>
```

- Returns: Effect's `Config.Boolean(name)`.

## Shared: logger

### Logger.layer

```ts
export const layer: Layer.Layer<never>
```

- Notes: replaces the default Effect logger with `Logger.fivemLogger` and sets `References.MinimumLogLevel` from the `rivo_fx:logLevel` convar, read once when the layer builds (`Info` when unset or invalid). Part of `FxServer.layer` and `FxClient.layer`.
- Example (server.cfg):

```cfg
set rivo_fx:logLevel Debug
```

### Logger.fivemLogger

```ts
export const fivemLogger: Logger.Logger<unknown, void>
```

- Notes: prints each line through `console.log` with FiveM color codes, for every level. FiveM's own `console.warn` and `console.error` would add a second prefix, so they are not used.

### Logger.formatLine(options)

```ts
export const formatLine: (options: Logger.Options<unknown>) => string
```

- Returns: `^5[INFO]^7 message`, with the pretty cause on the following lines when the log has one.

### Logger.parseLogLevel(value)

```ts
export const parseLogLevel: (value: string) => LogLevel.LogLevel | undefined
```

- Returns: the Effect level for a name, case-insensitive and trimmed (`"debug"` gives `"Debug"`), or `undefined`.

### Logger.convarLogLevel()

```ts
export const convarLogLevel: () => LogLevel.LogLevel
```

- Returns: the level named by `rivo_fx:logLevel`, or `"Info"`.

### Logger.colors

```ts
export const colors: Record<LogLevel.LogLevel, string>
// { All: "^7", Fatal: "^8", Error: "^1", Warn: "^3", Info: "^5", Debug: "^6", Trace: "^9", None: "^7" }
```

### Logger.LOG_LEVEL_CONVAR

```ts
export const LOG_LEVEL_CONVAR = "rivo_fx:logLevel"
```

## Shared: rate limits

### parseRateLimit(limit)

```ts
export type RateLimit = `${number}/${"s" | "m" | "h"}`
export interface ParsedRateLimit { readonly capacity: number; readonly periodMs: number }
export const parseRateLimit: (limit: RateLimit | string) => ParsedRateLimit
```

- Returns: `{ capacity: 10, periodMs: 1000 }` for `"10/s"`.
- Fails with: throws `Invalid rate limit "<limit>": expected "<n>/s", "<n>/m" or "<n>/h" with n > 0`. No spaces are allowed (the Lua parser accepts them).
- Example:

```ts
const { capacity, periodMs } = parseRateLimit("30/m")   // 30, 60000
```

### TokenBuckets

```ts
export class TokenBuckets {
  constructor(limit: ParsedRateLimit)
  take(key: string, now: number): boolean
  deletePrefix(prefix: string): void
  get size(): number
}
```

- Notes: a set of token buckets sharing one limit. Capacity `n`, refilled continuously at `n` per period. `take` returns `false` when the key's bucket is empty. Time is passed in, so it works with Effect's `Clock` and `TestClock`.
- Example:

```ts
const buckets = new TokenBuckets(parseRateLimit("1/m"))
const now = yield* Clock.currentTimeMillis
if (!buckets.take(`${source}|daily`, now)) yield* Effect.log("too soon")
```

### DEFAULT_RATE_LIMIT

```ts
export const DEFAULT_RATE_LIMIT: RateLimit   // "10/s"
```

## Shared: protocol helpers

`Protocol` holds the wire shapes and event names from [PROTOCOL.md](../PROTOCOL.md). You need them
only to talk to Rivo FX resources without the `Rpc` modules, or to test them.

### Protocol.reqEvent(resource)

```ts
export const reqEvent: (resource: string) => string      // "__rfx:<resource>:req"
export const resEvent: (resource: string) => string      // "__rfx:<resource>:res"
export const cancelEvent: (resource: string) => string   // "__rfx:<resource>:cancel"
export const SECURITY_EVENT = "rivo_fx:security"
```

- Notes: `resEvent` and `cancelEvent` follow the same pattern. `SECURITY_EVENT` is the local event every security event is mirrored to.

### Protocol.parseRequest(u)

```ts
export interface RpcRequest {
  readonly id: number
  readonly name: string
  readonly from: string
  readonly input: unknown
  readonly trace?: string
}
export const parseRequest: (u: unknown) => RpcRequest | undefined
```

- Returns: the request, or `undefined` when `id` is not an integer or `name`/`from` are not non-empty strings. A `trace` that is not a string of at most 64 characters is dropped, not rejected.

### Protocol.parseResponse(u)

```ts
export type RpcResponse =
  | { readonly id: number; readonly ok: true; readonly value: unknown }
  | { readonly id: number; readonly ok: false; readonly error: WireError }
export const parseResponse: (u: unknown) => RpcResponse | undefined
```

### Protocol.parseCancel(u)

```ts
export interface RpcCancel { readonly id: number; readonly from: string }
export const parseCancel: (u: unknown) => RpcCancel | undefined
```

### Protocol.parseTraceparent(s)

```ts
export const parseTraceparent: (s: string | undefined) => { traceId: string; spanId: string } | undefined
```

- Returns: the ids from a W3C traceparent (`00-<32 hex>-<16 hex>-<2 hex>`), or `undefined` for version `ff`, all-zero ids, or anything malformed.

### Protocol.formatTraceparent(traceId, spanId)

```ts
export const formatTraceparent: (traceId: string, spanId: string) => string | undefined
```

- Returns: `00-<traceId>-<spanId>-01`, or `undefined` when the ids are not W3C shaped.
- Example:

```ts
Protocol.formatTraceparent("0af7651916cd43dd8448eb211c80319c", "b7ad6b7169203331")
// "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
```

## Shared: RPC engine types

These types describe the engine both `Rpc` modules are built on. They are exported for advanced use
and tests; there is no public constructor for a host or caller besides the `RpcServer` and
`RpcClient` layers.

```ts
export interface Transport<P> {
  readonly listen: (event: string, callback: (peer: P, payload: unknown) => void) => () => void
  readonly send: (peer: P, event: string, payload: unknown) => void
  readonly peerKey: (peer: P) => string
}
export type RejectionKind = "invalid_payload" | "rate_limited" | "unknown_rpc"
export interface HostOptions<P> {
  readonly resource: string
  readonly onReject?: (peer: P, kind: RejectionKind, name: string, message?: string) => Effect.Effect<void>
}
export interface HostEntry<P> {
  readonly input: Schema.Decoder<unknown>
  readonly output?: Schema.Codec<unknown, unknown> | undefined
  readonly limiter?: TokenBuckets | undefined
  readonly handler: (peer: P, input: unknown) => Effect.Effect<unknown, unknown>
}
export interface Host<P> {
  readonly register: (name: string, entry: HostEntry<P>) => Effect.Effect<void, never, Scope.Scope>
}
export interface CallOptions {
  readonly resource?: string | undefined
  readonly timeout?: number | undefined
  readonly output?: Schema.Decoder<unknown> | undefined
  readonly errors?: Schema.Decoder<unknown> | undefined
}
export interface Caller<P> {
  readonly call: (peer: P, name: string, input: unknown, options?: CallOptions) => Effect.Effect<unknown, unknown>
}
```

## Error classes

Every class below is a `Schema.TaggedError`, so `Effect.catchTag` works on its `_tag`. All are
exported from `@rivolabs/fx` (and re-exported from `/server` and `/client`), except the asset and
entity errors, which live on the client modules.

| Class | Import | Fields | When |
|---|---|---|---|
| `RpcNotFound` | `@rivolabs/fx` | `name` | no handler with that name on the host |
| `RpcInvalidInput` | `@rivolabs/fx` | `name`, `message` | the input failed the host's schema |
| `RpcRateLimited` | `@rivolabs/fx` | `name` | the caller exceeded the handler's rate limit |
| `RpcInternalError` | `@rivolabs/fx` | `name` | the handler died, failed without a `_tag`, or its output failed to encode |
| `RpcTimeout` | `@rivolabs/fx` | `name`, `timeoutMs` | raised on the caller when no response arrived in time |
| `RpcInvalidOutput` | `@rivolabs/fx` | `name`, `message` | raised on the caller when the response failed `output` |
| `RemoteError` | `@rivolabs/fx` | `_tag` plus any fields | any other tag the host failed with, when `errors` did not decode it |
| `Assets.InvalidModel` | `@rivolabs/fx/client` | `model` (string or number) | model not in the CD image or not valid |
| `Assets.InvalidAnimDict` | `@rivolabs/fx/client` | `animDict` | `DoesAnimDictExist` is false |
| `Assets.AssetTimeout` | `@rivolabs/fx/client` | `kind` (`"model"`, `"animDict"`, `"ptfxAsset"`), `asset`, `timeoutMs` | the asset did not load in time |
| `Entity.EntityNotFound` | `@rivolabs/fx/client` | `entity` | the handle does not exist |
| `Entity.EntityTimeout` | `@rivolabs/fx/client` | `operation` (`"requestControl"`, `"fromNetId"`), `id`, `timeoutMs` | control or the network id did not resolve in time |

```ts
export type RpcError = RpcNotFound | RpcInvalidInput | RpcRateLimited | RpcInternalError | RpcTimeout | RpcInvalidOutput
export class RemoteError extends Data.Error<{ readonly _tag: string; readonly [field: string]: unknown }> {}
export interface WireError { readonly _tag: string; readonly [field: string]: unknown }
```

How errors cross the wire:

- Only expected failures with a string `_tag` cross. The host sends the error's own enumerable fields plus `_tag`, and `message` when it is a non-empty string. Functions, symbols and `stack` are dropped.
- A defect anywhere in the cause wins: the caller gets `RpcInternalError { name }` and the details stay in the host's log. Interruptions send nothing (a cancelled call) or are seen by the caller as a timeout.
- On the caller, the six protocol tags become their real classes. Other tags are decoded with `errors` when you pass it, and become `RemoteError` otherwise. A `RemoteError` keeps every field; read them with index access (`e["balance"]`, typed `unknown`). With `errors`, the runtime value is your class, but narrow with `instanceof` to get typed fields (see [Rpc.call](#rpccallname-input-options)).

See [Errors and gotchas](errors.md) for every tag in both languages.

## Tracing

- Every `Rpc.call` and `Rpc.callClient` runs in a span `rpc.client <name>` (kind `client`, attributes `rpc.name`, `rpc.target`). The request carries that span as a W3C `traceparent` in its `trace` field.
- The host runs the handler in a span `rpc.server <name>` (kind `server`, attributes `rpc.name`, `rpc.caller`) whose parent is the caller's span, so both halves share one trace id. A missing or malformed `trace` starts a new trace; it never rejects the request.
- This works in both directions and across languages: a Lua client's `Fx.rpc.call` continues into a TypeScript handler, and a TypeScript call continues into a Lua handler.
- The spans are ordinary Effect spans. To export them, provide an Effect tracer layer of your choice. The `/fxdev` devtools and the `rivo_fx` metrics and spans endpoints read Lua resources only; JS spans do not appear there, but the Lua half of a mixed trace does. See [Observability](observability.md).

```ts
const order = Rpc.call("shop:buy", { item: "water" }, { timeout: 5_000 }).pipe(
  Effect.withSpan("shop.checkout")   // parent of rpc.client shop:buy, which is the parent of rpc.server shop:buy
)
```

## Bundling a resource

Bundle each side into one IIFE file with `effect` and `@rivolabs/fx` inside. The repository's
[examples/js_example/build.mjs](../../examples/js_example/build.mjs) does this with esbuild (it
resolves `@rivolabs/fx` to the repo's `dist/`; in your own project, install the package instead).
A standalone version:

```js
// build.mjs: node build.mjs
import * as esbuild from "esbuild"

await Promise.all(["server", "client"].map((side) =>
  esbuild.build({
    entryPoints: [`src/${side}.ts`],
    outfile: `dist/${side}.js`,
    bundle: true,
    format: "iife",
    platform: "neutral",
    target: "es2020",
    mainFields: ["module", "main"],
    logLevel: "warning"
  })
))
```

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'

server_script 'dist/server.js'
client_script 'dist/client.js'
```

- `platform: "neutral"` keeps Node built-ins out. The client entry uses no Node APIs.
- `src/client.ts` must start with `import "@rivolabs/fx/polyfill"`.
- A JS resource does not need the `rivo_fx` Lua resource. It only talks to Lua resources over net events.
- Type-check each side with its own `tsconfig`: `@citizenfx/server` and `@citizenfx/client` declare conflicting globals.

## Interop with Lua

The JS package and the Lua library implement the same protocol, so:

- A Lua client calls a TypeScript server RPC with `Fx.rpc.call(name, input, { resource = '<js resource>' })`. A TypeScript client calls a Lua server RPC with `Rpc.call(name, input, { resource: "<lua resource>" })`. `resource` is required whenever the host is a different resource, because requests go to `__rfx:<target>:req` and the target defaults to the caller's own resource.
- The server side works the same way: Lua `Fx.rpc.callClient(src, name, input, { resource = ... })` reaches a JS client host, and JS `Rpc.callClient` reaches a Lua client host.
- Tagged errors cross both ways with their `_tag` and fields. A TypeScript `NotEnoughMoney { balance, wanted }` arrives in Lua as a table with `_tag = 'NotEnoughMoney'`, so `:catchTag('NotEnoughMoney', function(e) ... e.balance ... end)` works. A Lua `Fx.TaggedError('NotYours') { plate = 'ABC' }` arrives in TypeScript as `RemoteError` (or your class via `errors`).
- Protocol errors (`RpcTimeout`, `RpcInvalidInput`, ...) have the same tags and fields on both sides. `message` texts differ: Lua schema messages vs Effect `SchemaError` messages.
- Timeouts and cancellation cross too: a Lua caller that times out sends the cancel event and the TypeScript handler is interrupted.
- Net events are plain FiveM events with one payload argument on both sides, so `Fx.net.send('js_res:deposit', { amount = 100 })` reaches a JS `Net.handle`.
- Payload shapes: Lua has no `null` and no empty-array/empty-object distinction. An optional field set to `null` in JS is absent in Lua, and `{}` and `[]` are the same empty table. Use [`rivo-fx gen`](cli.md) to keep schemas identical on both sides.

```lua
-- Lua client, calling the TypeScript server from examples/js_example
local JS = { resource = 'js_example', timeout = 5000 }
Fx.runFork(Fx.rpc.call('js_example:withdraw', { amount = 1000 }, JS)
  :catchTag('NotEnoughMoney', function(e)
    return Fx.succeed(('have %d, wanted %d'):format(e.balance, e.wanted))
  end))
```
