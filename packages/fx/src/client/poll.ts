import { Effect } from "effect"

/**
 * Re-runs `check` every `intervalMs` (the FiveM `Wait` loop) until it returns
 * a value, failing with `onTimeout()` after `timeoutMs`.
 */
export const poll = <A, E>(
  check: () => A | undefined,
  options: { readonly timeoutMs: number; readonly intervalMs: number; readonly onTimeout: () => E }
): Effect.Effect<A, E> => {
  const loop: Effect.Effect<A> = Effect.suspend(() => {
    const value = check()
    return value === undefined ? Effect.andThen(Effect.sleep(options.intervalMs), loop) : Effect.succeed(value)
  })
  return Effect.timeoutOrElse(loop, {
    duration: options.timeoutMs,
    orElse: () => Effect.fail(options.onTimeout())
  })
}
