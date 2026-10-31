import { Context, Effect, Layer, Schema, type Scope } from "effect"
import type { RemoteError, RpcError } from "../shared/errors.js"
import { resourceName } from "../shared/fivem.js"
import { DEFAULT_RATE_LIMIT, type RateLimit } from "../shared/RateLimit.js"
import { type CallOptions, type Caller, type Host, makeCaller, makeHost, type Transport } from "../shared/RpcCore.js"
import { interruptOnDrop } from "./players.js"
import { RateLimiter } from "./RateLimiter.js"
import { SecurityEvents } from "./SecurityEvents.js"

/** Net events from players; `source` is the player id. Responses go back with `TriggerClientEvent`. */
export const serverTransport: Transport<number> = {
  listen: (event, callback) => {
    const listener = (payload: unknown) => {
      const player = Number(source)
      if (Number.isInteger(player) && player > 0) callback(player, payload)
    }
    onNet(event, listener)
    return () => removeEventListener(event, listener)
  },
  send: (player, event, payload) => TriggerClientEvent(event, player, payload),
  peerKey: (player) => String(player)
}

/** The server's RPC host (client → server calls) and caller (server → client calls). */
export class RpcServer extends Context.Service<RpcServer, {
  readonly host: Host<number>
  readonly caller: Caller<number>
}>()("@rivolabs/fx/RpcServer") {
  static readonly layer: Layer.Layer<RpcServer, never, SecurityEvents> = Layer.effect(
    RpcServer,
    Effect.gen(function*() {
      const security = yield* SecurityEvents
      const resource = resourceName()
      const host = yield* makeHost(serverTransport, {
        resource,
        onReject: (player, kind, name, message) => security.publish({ kind, source: player, name, message })
      })
      const caller = yield* makeCaller(serverTransport, resource)
      return RpcServer.of({ host, caller })
    })
  )
}

export interface RegisterOptions<I extends Schema.Decoder<unknown>, A> {
  /** Decodes the request input. A mismatch answers `RpcInvalidInput` and publishes a SecurityEvent. */
  readonly input: I
  /** Encodes the handler's result before it is sent. */
  readonly output?: Schema.Codec<A, unknown> | undefined
  /** Per-player token bucket for this RPC. Defaults to `"10/s"`. `false` disables it. */
  readonly rateLimit?: RateLimit | false | undefined
}

/**
 * Registers a client → server RPC for the lifetime of the current scope.
 *
 * The handler's tagged errors are sent to the caller and rebuilt there.
 * Defects and interruptions become `RpcInternalError`.
 *
 * ```ts
 * yield* Rpc.register("bank:withdraw", { input: Schema.Struct({ amount: Schema.Int }) },
 *   (source, { amount }) => withdraw(source, amount))   // may fail with NotEnoughMoney
 * ```
 */
export const register = <I extends Schema.Decoder<unknown>, A, E, R = never>(
  name: string,
  options: RegisterOptions<I, A>,
  handler: (source: number, input: I["Type"]) => Effect.Effect<A, E, R>
): Effect.Effect<void, never, RpcServer | RateLimiter | Scope.Scope | R> =>
  Effect.gen(function*() {
    const { host } = yield* RpcServer
    const limiter = yield* RateLimiter
    const context = yield* Effect.context<R>()
    yield* host.register(name, {
      input: options.input,
      output: options.output,
      limiter: options.rateLimit === false
        ? undefined
        : limiter.buckets("rpc", name, options.rateLimit ?? DEFAULT_RATE_LIMIT),
      handler: (player, input) => interruptOnDrop(player, Effect.provideContext(handler(player, input as I["Type"]), context))
    })
  })

export interface CallClientOptions<A, E> extends Omit<CallOptions, "output" | "errors"> {
  /** Validates the response value. A mismatch fails with `RpcInvalidOutput`. */
  readonly output?: Schema.Decoder<A> | undefined
  /** Decodes known error tags into your own classes. */
  readonly errors?: Schema.Decoder<E> | undefined
}

/**
 * Calls an RPC registered on `player`'s client. Interrupting the call (or
 * timing out) sends the cancel event, and the client interrupts its handler.
 */
export const callClient = <A = unknown, E = never>(
  player: number,
  name: string,
  input: unknown,
  options?: CallClientOptions<A, E>
): Effect.Effect<A, E | RpcError | RemoteError, RpcServer> =>
  RpcServer.use(({ caller }) =>
    caller.call(player, name, input, options) as Effect.Effect<A, E | RpcError | RemoteError>
  )
