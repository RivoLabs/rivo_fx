import { Cause, Clock, Effect, Exit, FiberSet, Schema, type Scope } from "effect"
import { DEFAULT_RATE_LIMIT, type RateLimit } from "../shared/RateLimit.js"
import { interruptOnDrop } from "./players.js"
import { RateLimiter } from "./RateLimiter.js"
import { SecurityEvents } from "./SecurityEvents.js"

export interface HandleOptions {
  /** Per-player token bucket for this event. Defaults to `"10/s"`. `false` disables it. */
  readonly rateLimit?: RateLimit | false | undefined
}

/**
 * Registers a validated, rate-limited net event for the lifetime of the
 * current scope.
 *
 * The event carries exactly one argument, the payload. It is decoded with
 * `schema` before `handler` runs. An invalid payload or a rate-limit hit
 * publishes a `SecurityEvent` and the handler does not run.
 *
 * ```ts
 * yield* Net.handle("shop:buy", Schema.Struct({ item: Schema.String }), (source, { item }) =>
 *   Effect.log(`${source} bought ${item}`))
 * ```
 */
export const handle = <S extends Schema.Decoder<unknown>, R = never>(
  name: string,
  schema: S,
  handler: (source: number, input: S["Type"]) => Effect.Effect<unknown, unknown, R>,
  options: HandleOptions = {}
): Effect.Effect<void, never, SecurityEvents | RateLimiter | Scope.Scope | R> =>
  Effect.gen(function*() {
    const security = yield* SecurityEvents
    const limiter = yield* RateLimiter
    const buckets = options.rateLimit === false
      ? undefined
      : limiter.buckets("net", name, options.rateLimit ?? DEFAULT_RATE_LIMIT)
    const decode = Schema.decodeUnknownExit(schema)
    const run = yield* FiberSet.makeRuntime<R>()

    const process = (player: number, payload: unknown) =>
      Effect.gen(function*() {
        if (buckets !== undefined && !buckets.take(`${player}|${name}`, yield* Clock.currentTimeMillis)) {
          return yield* security.publish({ kind: "rate_limited", source: player, name })
        }
        const decoded = decode(payload)
        if (Exit.isFailure(decoded)) {
          const error = Cause.findErrorOption(decoded.cause)
          return yield* security.publish({
            kind: "invalid_payload",
            source: player,
            name,
            message: error._tag === "Some" ? error.value.message : "invalid payload"
          })
        }
        yield* interruptOnDrop(player, handler(player, decoded.value as S["Type"])).pipe(
          Effect.catchCause((cause) =>
            Cause.hasInterruptsOnly(cause) ? Effect.void : Effect.logError(`net event "${name}" failed`, cause)
          )
        )
      })

    const listener = (payload: unknown) => {
      const player = Number(source)
      // Only players send net events; a local TriggerEvent has no player source.
      if (!Number.isInteger(player) || player <= 0) return
      run(process(player, payload))
    }
    onNet(name, listener)
    yield* Effect.addFinalizer(() => Effect.sync(() => removeEventListener(name, listener)))
  })

/** `TriggerClientEvent(name, player, payload)`. */
export const emitClient = (name: string, player: number, payload?: unknown): Effect.Effect<void> =>
  Effect.sync(() => TriggerClientEvent(name, player, payload))

/** `TriggerClientEvent(name, -1, payload)`: sends to every player. */
export const broadcast = (name: string, payload?: unknown): Effect.Effect<void> =>
  Effect.sync(() => TriggerClientEvent(name, -1, payload))
