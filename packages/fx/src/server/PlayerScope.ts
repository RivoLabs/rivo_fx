import { Context, Effect, Exit, type Fiber, Layer, Scope } from "effect"
import { onPlayerDropped } from "./players.js"

/**
 * One `Scope` per connected player, closed on `playerDropped` (and when the
 * resource stops). Fork per-player work into it or attach finalizers to it,
 * and it is cleaned up when the player leaves.
 */
export class PlayerScopes extends Context.Service<PlayerScopes, {
  /** The player's scope, created on first use. */
  readonly scope: (player: number) => Effect.Effect<Scope.Scope>
}>()("@rivolabs/fx/PlayerScopes") {
  static readonly layer: Layer.Layer<PlayerScopes> = Layer.effect(
    PlayerScopes,
    Effect.gen(function*() {
      const parent = yield* Effect.scope
      const scopes = new Map<number, Scope.Closeable>()

      const off = onPlayerDropped((player) => {
        const scope = scopes.get(player)
        if (scope === undefined) return
        scopes.delete(player)
        Effect.runFork(Scope.close(scope, Exit.void))
      })
      yield* Effect.addFinalizer(() => Effect.sync(off))

      return PlayerScopes.of({
        scope: (player) =>
          Effect.suspend(() => {
            const existing = scopes.get(player)
            if (existing !== undefined) return Effect.succeed(existing)
            return Scope.fork(parent).pipe(
              Effect.tap((scope) =>
                Effect.sync(() => scopes.set(player, scope)).pipe(
                  Effect.andThen(Scope.addFinalizer(scope, Effect.sync(() => scopes.delete(player))))
                )
              )
            )
          })
      })
    })
  )
}

/** The scope for `player`. It closes when the player drops. */
export const get = (player: number): Effect.Effect<Scope.Scope, never, PlayerScopes> =>
  PlayerScopes.use((s) => s.scope(player))

/** Forks `effect` into the player's scope: it is interrupted when the player drops. */
export const fork = <A, E, R>(
  player: number,
  effect: Effect.Effect<A, E, R>
): Effect.Effect<Fiber.Fiber<A, E>, never, PlayerScopes | R> =>
  Effect.flatMap(get(player), (scope) => Effect.forkIn(effect, scope))

/** Runs `finalizer` when the player drops (or the resource stops). */
export const addFinalizer = <R>(
  player: number,
  finalizer: Effect.Effect<void, never, R>
): Effect.Effect<void, never, PlayerScopes | R> =>
  Effect.gen(function*() {
    const scope = yield* get(player)
    const context = yield* Effect.context<R>()
    yield* Scope.addFinalizer(scope, Effect.provideContext(finalizer, context))
  })

/** Provides the player's scope to `effect`, so its scoped resources live until the player drops. */
export const scoped = <A, E, R>(
  player: number,
  effect: Effect.Effect<A, E, R>
): Effect.Effect<A, E, PlayerScopes | Exclude<R, Scope.Scope>> =>
  Effect.flatMap(get(player), (scope) => Scope.provide(scope)(effect))
