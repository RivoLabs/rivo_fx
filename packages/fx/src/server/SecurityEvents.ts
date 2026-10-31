import { Context, Effect, Layer, PubSub, type Scope, Stream } from "effect"
import { resourceName } from "../shared/fivem.js"
import { SECURITY_EVENT } from "../shared/protocol.js"

/** Something a client sent that the server rejected. */
export interface SecurityEvent {
  readonly kind: "invalid_payload" | "rate_limited" | "unknown_rpc"
  /** The player id that sent it. */
  readonly source: number
  /** The net event or RPC name. */
  readonly name: string
  readonly message?: string | undefined
}

/**
 * Publishes {@link SecurityEvent}s inside the resource and mirrors each one to
 * `TriggerEvent("rivo_fx:security", event, resourceName)` so an anticheat
 * resource can listen to every resource in one place.
 */
export class SecurityEvents extends Context.Service<SecurityEvents, {
  readonly publish: (event: SecurityEvent) => Effect.Effect<void>
  /** Subscribes for the lifetime of the current scope. Events published before subscribing are not seen. */
  readonly subscribe: Effect.Effect<PubSub.Subscription<SecurityEvent>, never, Scope.Scope>
  readonly stream: Stream.Stream<SecurityEvent>
}>()("@rivolabs/fx/SecurityEvents") {
  static readonly layer: Layer.Layer<SecurityEvents> = Layer.effect(
    SecurityEvents,
    Effect.gen(function*() {
      const hub = yield* Effect.acquireRelease(PubSub.unbounded<SecurityEvent>(), PubSub.shutdown)
      const resource = resourceName()
      return SecurityEvents.of({
        publish: (event) =>
          Effect.gen(function*() {
            const wire: SecurityEvent = event.message === undefined
              ? { kind: event.kind, source: event.source, name: event.name }
              : { kind: event.kind, source: event.source, name: event.name, message: event.message }
            const line =
              `security: ${wire.kind} from player ${wire.source} on "${wire.name}"${wire.message ? `: ${wire.message}` : ""}`
            // A flood produces one rate_limited event per message; keep those out of the default log.
            yield* (wire.kind === "rate_limited" ? Effect.logDebug(line) : Effect.logWarning(line))
            yield* PubSub.publish(hub, wire)
            emit(SECURITY_EVENT, wire, resource)
          }),
        subscribe: PubSub.subscribe(hub),
        stream: Stream.fromPubSub(hub)
      })
    })
  )
}

export const publish = (event: SecurityEvent): Effect.Effect<void, never, SecurityEvents> =>
  SecurityEvents.use((s) => s.publish(event))

export const subscribe: Effect.Effect<PubSub.Subscription<SecurityEvent>, never, SecurityEvents | Scope.Scope> =
  SecurityEvents.use((s) => s.subscribe)

export const stream: Stream.Stream<SecurityEvent, never, SecurityEvents> = Stream.unwrap(
  SecurityEvents.use((s) => Effect.succeed(s.stream))
)
