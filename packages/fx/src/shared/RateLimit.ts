/**
 * Token-bucket rate limits, as specified in docs/PROTOCOL.md.
 *
 * A limit is written `"<n>/s"`, `"<n>/m"` or `"<n>/h"`: capacity `n`, refilled
 * continuously at `n` per period, one bucket per key.
 */

export type RateLimit = `${number}/${"s" | "m" | "h"}`

export interface ParsedRateLimit {
  readonly capacity: number
  readonly periodMs: number
}

export const DEFAULT_RATE_LIMIT: RateLimit = "10/s"

const PERIODS = { s: 1_000, m: 60_000, h: 3_600_000 } as const

/** Parses `"10/s"` into `{ capacity: 10, periodMs: 1000 }`. Throws on malformed input. */
export const parse = (limit: RateLimit | string): ParsedRateLimit => {
  const match = /^(\d+)\/([smh])$/.exec(limit)
  if (match === null || Number(match[1]) <= 0) {
    throw new Error(`Invalid rate limit "${limit}": expected "<n>/s", "<n>/m" or "<n>/h" with n > 0`)
  }
  return { capacity: Number(match[1]), periodMs: PERIODS[match[2] as keyof typeof PERIODS] }
}

interface Bucket {
  tokens: number
  updatedAt: number
}

/**
 * A set of token buckets sharing one limit.
 *
 * Time is passed in by the caller (from Effect's `Clock`), so the buckets are
 * pure and testable with `TestClock`.
 */
export class TokenBuckets {
  readonly #buckets = new Map<string, Bucket>()
  readonly #capacity: number
  readonly #refillPerMs: number

  constructor(limit: ParsedRateLimit) {
    this.#capacity = limit.capacity
    this.#refillPerMs = limit.capacity / limit.periodMs
  }

  /** Takes one token from `key`'s bucket. Returns `false` when the bucket is empty. */
  take(key: string, now: number): boolean {
    let bucket = this.#buckets.get(key)
    if (bucket === undefined) {
      bucket = { tokens: this.#capacity, updatedAt: now }
      this.#buckets.set(key, bucket)
    } else {
      const elapsed = Math.max(0, now - bucket.updatedAt)
      bucket.tokens = Math.min(this.#capacity, bucket.tokens + elapsed * this.#refillPerMs)
      bucket.updatedAt = now
    }
    if (bucket.tokens < 1) return false
    bucket.tokens -= 1
    return true
  }

  /** Forgets every bucket whose key starts with `prefix` (used when a player drops). */
  deletePrefix(prefix: string): void {
    for (const key of this.#buckets.keys()) {
      if (key.startsWith(prefix)) this.#buckets.delete(key)
    }
  }

  get size(): number {
    return this.#buckets.size
  }
}
