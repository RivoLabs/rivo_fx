import { Cause, Effect, Exit, FiberSet, Schema, type Scope } from "effect"

/**
 * Registers a validated net event from the server for the lifetime of the
 * current scope. The event carries exactly one argument, decoded with
 * `schema`. An invalid payload is logged and the handler does not run.
 */
export const handle = <S extends Schema.Decoder<unknown>, R = never>(
  name: string,
  schema: S,
  handler: (input: S["Type"]) => Effect.Effect<unknown, unknown, R>
): Effect.Effect<void, never, Scope.Scope | R> =>
  Effect.gen(function*() {
    const decode = Schema.decodeUnknownExit(schema)
    const run = yield* FiberSet.makeRuntime<R>()
    const listener = (payload: unknown) => {
      run(Effect.suspend(() => {
        const decoded = decode(payload)
        if (Exit.isFailure(decoded)) {
          return Effect.logWarning(`net event "${name}": invalid payload`, decoded.cause)
        }
        return handler(decoded.value as S["Type"]).pipe(
          Effect.catchCause((cause) =>
            Cause.hasInterruptsOnly(cause) ? Effect.void : Effect.logError(`net event "${name}" failed`, cause)
          )
        )
      }))
    }
    onNet(name, listener)
    yield* Effect.addFinalizer(() => Effect.sync(() => removeEventListener(name, listener)))
  })

/** `TriggerServerEvent(name, payload)`. */
export const emitServer = (name: string, payload?: unknown): Effect.Effect<void> =>
  Effect.sync(() => TriggerServerEvent(name, payload))
