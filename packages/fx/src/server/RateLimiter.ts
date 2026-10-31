import { Context, Effect, Layer } from "effect"
import { parse, type RateLimit, TokenBuckets } from "../shared/RateLimit.js"
import { onPlayerDropped } from "./players.js"

/**
 * Owns the per-player token buckets used by `Net.handle` and `Rpc.register`,
 * and forgets a player's buckets when they drop.
 */
export class RateLimiter extends Context.Service<RateLimiter, {
  /**
   * The bucket set for one handler. Keys are `"<player>|<name>"`, so each
   * (player, event or RPC name) pair gets its own bucket.
   */
  readonly buckets: (kind: "net" | "rpc", name: string, limit: RateLimit) => TokenBuckets
}>()("@rivolabs/fx/RateLimiter") {
  static readonly layer: Layer.Layer<RateLimiter> = Layer.effect(
    RateLimiter,
    Effect.gen(function*() {
      const all = new Map<string, TokenBuckets>()
      const off = onPlayerDropped((player) => {
        for (const buckets of all.values()) buckets.deletePrefix(`${player}|`)
      })
      yield* Effect.addFinalizer(() => Effect.sync(off))
      return RateLimiter.of({
        buckets: (kind, name, limit) => {
          const key = `${kind}|${name}|${limit}`
          let buckets = all.get(key)
          if (buckets === undefined) {
            buckets = new TokenBuckets(parse(limit))
            all.set(key, buckets)
          }
          return buckets
        }
      })
    })
  )
}
