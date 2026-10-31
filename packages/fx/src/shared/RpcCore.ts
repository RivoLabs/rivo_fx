/**
 * The RPC engine from docs/PROTOCOL.md, independent of which side it runs on.
 *
 * A `Transport` says how to listen for and send net events, and what a "peer"
 * is: a player id on the server, the server itself on a client. The server and
 * client `Rpc` modules build a host and a caller on top of their transport.
 */
import { Cause, Clock, Effect, Exit, FiberMap, Schema, Scope, Tracer } from "effect"
import {
  decodeError,
  encodeError,
  RpcInternalError,
  RpcInvalidInput,
  RpcInvalidOutput,
  RpcNotFound,
  RpcRateLimited,
  RpcTimeout,
  type WireError
} from "./errors.js"
import {
  cancelEvent,
  formatTraceparent,
  parseCancel,
  parseRequest,
  parseResponse,
  parseTraceparent,
  reqEvent,
  resEvent,
  type RpcResponse
} from "./protocol.js"
import type { TokenBuckets } from "./RateLimit.js"

export interface Transport<P> {
  /** Listens on a net event. The callback gets the sending peer and the event's single argument. */
  readonly listen: (event: string, callback: (peer: P, payload: unknown) => void) => () => void
  /** Sends a net event with exactly one argument to `peer`. */
  readonly send: (peer: P, event: string, payload: unknown) => void
  /** A string that identifies `peer` in request keys and rate-limit buckets. */
  readonly peerKey: (peer: P) => string
}

export type RejectionKind = "invalid_payload" | "rate_limited" | "unknown_rpc"

export interface HostOptions<P> {
  /** This resource's name: the host listens on `__rfx:<resource>:req` and `:cancel`. */
  readonly resource: string
  /** Called when a peer's request is rejected (used to publish SecurityEvents on the server). */
  readonly onReject?: (peer: P, kind: RejectionKind, name: string, message?: string) => Effect.Effect<void>
}

export interface HostEntry<P> {
  readonly input: Schema.Decoder<unknown>
  readonly output?: Schema.Codec<unknown, unknown> | undefined
  readonly limiter?: TokenBuckets | undefined
  readonly handler: (peer: P, input: unknown) => Effect.Effect<unknown, unknown>
}

export interface Host<P> {
  /** Adds a handler for the lifetime of the current scope. A later registration of the same name replaces it. */
  readonly register: (name: string, entry: HostEntry<P>) => Effect.Effect<void, never, Scope.Scope>
}

const formatIssue = (error: Schema.SchemaError): string => error.message

/** Builds the response for a finished handler. Only tagged errors cross the wire. */
const responseFor = (id: number, name: string, exit: Exit.Exit<unknown, unknown>): RpcResponse => {
  if (Exit.isSuccess(exit)) return { id, ok: true, value: exit.value }
  // A defect anywhere in the cause wins: its details never cross the wire.
  const error = Cause.findErrorOption(exit.cause)
  const wire: WireError = error._tag === "Some" && !Cause.hasDies(exit.cause)
    ? encodeError(name, error.value)
    : encodeError(name, new RpcInternalError({ name }))
  return { id, ok: false, error: wire }
}

export const makeHost = <P>(transport: Transport<P>, options: HostOptions<P>): Effect.Effect<Host<P>, never, Scope.Scope> =>
  Effect.gen(function*() {
    const entries = new Map<string, HostEntry<P>>()
    const running = yield* FiberMap.make<string>()
    const run = yield* FiberMap.runtime(running)<never>()
    const cancelled = new Set<string>()
    const reject = (peer: P, kind: RejectionKind, name: string, message?: string) =>
      options.onReject ? options.onReject(peer, kind, name, message) : Effect.void

    let rejected = 0

    const onRequest = (peer: P, payload: unknown): void => {
      const request = parseRequest(payload)
      if (request === undefined) {
        run(`malformed|${++rejected}`, reject(peer, "invalid_payload", reqEvent(options.resource), "malformed RPC request"))
        return
      }
      const { id, name, from } = request
      const key = `${transport.peerKey(peer)}|${from}|${id}`
      const reply = (response: RpcResponse) => Effect.sync(() => transport.send(peer, resEvent(from), response))
      const fail = (error: { readonly _tag: string }) => reply({ id, ok: false, error: encodeError(name, error) })

      const handle = Effect.gen(function*() {
        const entry = entries.get(name)
        if (entry === undefined) {
          yield* reject(peer, "unknown_rpc", name)
          return yield* fail(new RpcNotFound({ name }))
        }
        if (entry.limiter !== undefined) {
          const now = yield* Clock.currentTimeMillis
          if (!entry.limiter.take(`${transport.peerKey(peer)}|${name}`, now)) {
            yield* reject(peer, "rate_limited", name)
            return yield* fail(new RpcRateLimited({ name }))
          }
        }
        const decoded = Schema.decodeUnknownExit(entry.input)(request.input)
        if (Exit.isFailure(decoded)) {
          const error = Cause.findErrorOption(decoded.cause)
          const message = error._tag === "Some" ? formatIssue(error.value) : "invalid input"
          yield* reject(peer, "invalid_payload", name, message)
          return yield* fail(new RpcInvalidInput({ name, message }))
        }
        const output = entry.output
        const remote = parseTraceparent(request.trace)
        const program = entry.handler(peer, decoded.value).pipe(
          Effect.flatMap((value) =>
            output === undefined ? Effect.succeed(value) : Effect.orDie(Schema.encodeUnknownEffect(output)(value))
          ),
          Effect.tapCause((cause) =>
            Cause.hasDies(cause) ? Effect.logError(`RPC "${name}" died`, cause) : Effect.void
          ),
          // joins the caller's trace when the request carries one (docs/PROTOCOL.md)
          Effect.withSpan(`rpc.server ${name}`, {
            kind: "server",
            attributes: { "rpc.name": name, "rpc.caller": from },
            ...(remote === undefined ? {} : { parent: Tracer.externalSpan(remote) })
          })
        )
        yield* program.pipe(
          Effect.onExit((exit) => {
            if (cancelled.delete(key)) return Effect.void
            // interrupted (player dropped, resource stopping): nobody to answer
            if (Exit.isFailure(exit) && Cause.hasInterruptsOnly(exit.cause)) return Effect.void
            return reply(responseFor(id, name, exit))
          }),
          Effect.ignore
        )
      })
      run(key, handle, { onlyIfMissing: true })
    }

    const offReq = transport.listen(reqEvent(options.resource), onRequest)
    const offCancel = transport.listen(cancelEvent(options.resource), (peer, payload) => {
      const cancel = parseCancel(payload)
      if (cancel === undefined) return
      const key = `${transport.peerKey(peer)}|${cancel.from}|${cancel.id}`
      if (!FiberMap.hasUnsafe(running, key)) return
      cancelled.add(key)
      run(`${key}|cancel`, FiberMap.remove(running, key))
    })
    yield* Effect.addFinalizer(() =>
      Effect.sync(() => {
        offReq()
        offCancel()
      })
    )

    return {
      register: (name, entry) =>
        Effect.acquireRelease(
          Effect.sync(() => entries.set(name, entry)),
          () => Effect.sync(() => {
            if (entries.get(name) === entry) entries.delete(name)
          })
        ).pipe(Effect.asVoid)
    } satisfies Host<P>
  })

export interface CallOptions {
  /** Resource that hosts the RPC. Defaults to the caller's own resource. */
  readonly resource?: string | undefined
  /** Milliseconds before the call fails with `RpcTimeout`. Defaults to 10 000. */
  readonly timeout?: number | undefined
  /** Validates the response value. A mismatch fails with `RpcInvalidOutput`. */
  readonly output?: Schema.Decoder<unknown> | undefined
  /** Decodes known error tags into your own classes (e.g. a `Schema.Union` of `Schema.TaggedError`s). */
  readonly errors?: Schema.Decoder<unknown> | undefined
}

export const DEFAULT_TIMEOUT_MS = 10_000

export interface Caller<P> {
  readonly call: (peer: P, name: string, input: unknown, options?: CallOptions) => Effect.Effect<unknown, unknown>
}

export const makeCaller = <P>(transport: Transport<P>, resource: string): Effect.Effect<Caller<P>, never, Scope.Scope> =>
  Effect.gen(function*() {
    let nextId = 0
    const pending = new Map<string, (response: RpcResponse) => void>()

    const off = transport.listen(resEvent(resource), (peer, payload) => {
      const response = parseResponse(payload)
      if (response === undefined) return
      const resolve = pending.get(`${transport.peerKey(peer)}|${response.id}`)
      resolve?.(response)
    })
    yield* Effect.addFinalizer(() => Effect.sync(off))

    const call = (peer: P, name: string, input: unknown, options: CallOptions = {}) => {
      const target = options.resource ?? resource
      const timeoutMs = options.timeout ?? DEFAULT_TIMEOUT_MS
      const send = (trace: string | undefined) => Effect.callback<RpcResponse>((resume) => {
        const id = ++nextId
        const key = `${transport.peerKey(peer)}|${id}`
        pending.set(key, (response) => {
          pending.delete(key)
          resume(Effect.succeed(response))
        })
        transport.send(peer, reqEvent(target), { id, name, from: resource, input, ...(trace === undefined ? {} : { trace }) })
        // Runs only when the caller is interrupted (including by the timeout).
        return Effect.sync(() => {
          if (pending.delete(key)) transport.send(peer, cancelEvent(target), { id, from: resource })
        })
      })
      // the request carries this call's span, so the host's span joins its trace
      const request = Effect.flatMap(Effect.orDie(Effect.currentSpan), (span) => send(formatTraceparent(span.traceId, span.spanId)))
      return request.pipe(
        Effect.timeoutOrElse({
          duration: timeoutMs,
          orElse: () => Effect.fail(new RpcTimeout({ name, timeoutMs }))
        }),
        Effect.flatMap((response): Effect.Effect<unknown, unknown> => {
          if (!response.ok) return Effect.fail(decodeError(name, response.error, options.errors))
          if (options.output === undefined) return Effect.succeed(response.value)
          const decoded = Schema.decodeUnknownExit(options.output)(response.value)
          if (Exit.isSuccess(decoded)) return Effect.succeed(decoded.value)
          const error = Cause.findErrorOption(decoded.cause)
          return Effect.fail(
            new RpcInvalidOutput({ name, message: error._tag === "Some" ? error.value.message : "invalid output" })
          )
        }),
        Effect.withSpan(`rpc.client ${name}`, { kind: "client", attributes: { "rpc.name": name, "rpc.target": target } })
      )
    }

    return { call } satisfies Caller<P>
  })
