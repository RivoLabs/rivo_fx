import { Context, Effect, Layer, Schema, type Scope } from "effect"
import type { RemoteError, RpcError } from "../shared/errors.js"
import { resourceName } from "../shared/fivem.js"
import { type CallOptions, type Caller, type Host, makeCaller, makeHost, type Transport } from "../shared/RpcCore.js"

/** The only peer a client talks to. */
export type Server = "server"

/** Net events from the server. Requests and responses go back with `TriggerServerEvent`. */
export const clientTransport: Transport<Server> = {
  listen: (event, callback) => {
    const listener = (payload: unknown) => callback("server", payload)
    onNet(event, listener)
    return () => removeEventListener(event, listener)
  },
  send: (_server, event, payload) => TriggerServerEvent(event, payload),
  peerKey: () => "server"
}

/** The client's RPC caller (client → server calls) and host (server → client calls). */
export class RpcClient extends Context.Service<RpcClient, {
  readonly host: Host<Server>
  readonly caller: Caller<Server>
}>()("@rivolabs/fx/RpcClient") {
  static readonly layer: Layer.Layer<RpcClient> = Layer.effect(
    RpcClient,
    Effect.gen(function*() {
      const resource = resourceName()
      const host = yield* makeHost(clientTransport, { resource })
      const caller = yield* makeCaller(clientTransport, resource)
      return RpcClient.of({ host, caller })
    })
  )
}

export interface ClientCallOptions<A, E> extends Omit<CallOptions, "output" | "errors"> {
  /** Validates the response value. A mismatch fails with `RpcInvalidOutput`. */
  readonly output?: Schema.Decoder<A> | undefined
  /** Decodes known error tags into your own classes (e.g. a `Schema.Union` of `Schema.TaggedError`s). */
  readonly errors?: Schema.Decoder<E> | undefined
}

/**
 * Calls a server RPC. Fails with the host's tagged error rebuilt (a
 * `RemoteError` with the same `_tag` and fields, or your own class when
 * `errors` decodes it) or with one of the protocol errors.
 *
 * Interrupting the call, including by `timeout`, sends the cancel event.
 *
 * ```ts
 * const balance = yield* Rpc.call("bank:withdraw", { amount: 50 }, { output: Schema.Number }).pipe(
 *   Effect.catchTag("NotEnoughMoney", (e) => Effect.succeed(0)))
 * ```
 */
export const call = <A = unknown, E = never>(
  name: string,
  input: unknown,
  options?: ClientCallOptions<A, E>
): Effect.Effect<A, E | RpcError | RemoteError, RpcClient> =>
  RpcClient.use(({ caller }) =>
    caller.call("server", name, input, options) as Effect.Effect<A, E | RpcError | RemoteError>
  )

export interface RegisterOptions<I extends Schema.Decoder<unknown>, A> {
  /** Decodes the request input. A mismatch answers `RpcInvalidInput`. */
  readonly input: I
  /** Encodes the handler's result before it is sent. */
  readonly output?: Schema.Codec<A, unknown> | undefined
}

/** Registers a server → client RPC for the lifetime of the current scope. */
export const register = <I extends Schema.Decoder<unknown>, A, E, R = never>(
  name: string,
  options: RegisterOptions<I, A>,
  handler: (input: I["Type"]) => Effect.Effect<A, E, R>
): Effect.Effect<void, never, RpcClient | Scope.Scope | R> =>
  Effect.gen(function*() {
    const { host } = yield* RpcClient
    const context = yield* Effect.context<R>()
    yield* host.register(name, {
      input: options.input,
      output: options.output,
      handler: (_server, input) => Effect.provideContext(handler(input as I["Type"]), context)
    })
  })
