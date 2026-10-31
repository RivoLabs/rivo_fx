import { describe, expect, it } from "vitest"
import { parse, TokenBuckets } from "../../src/shared/RateLimit.js"

describe("rate limit parsing", () => {
  it("parses per second, minute and hour", () => {
    expect(parse("10/s")).toEqual({ capacity: 10, periodMs: 1_000 })
    expect(parse("30/m")).toEqual({ capacity: 30, periodMs: 60_000 })
    expect(parse("5/h")).toEqual({ capacity: 5, periodMs: 3_600_000 })
  })

  it("rejects malformed limits", () => {
    for (const bad of ["10", "10/d", "0/s", "-1/s", "a/s", "10/ s"]) {
      expect(() => parse(bad)).toThrow(/Invalid rate limit/)
    }
  })
})

describe("token buckets", () => {
  it("allows a burst up to capacity, then refuses", () => {
    const buckets = new TokenBuckets(parse("3/s"))
    expect([1, 2, 3, 4].map(() => buckets.take("1|ev", 0))).toEqual([true, true, true, false])
  })

  it("refills continuously at n per period", () => {
    const buckets = new TokenBuckets(parse("10/s"))
    for (let i = 0; i < 10; i++) expect(buckets.take("k", 0)).toBe(true)
    expect(buckets.take("k", 0)).toBe(false)
    // 10/s refills one token every 100 ms, not all ten at the end of the second
    expect(buckets.take("k", 99)).toBe(false)
    // 200 ms in: two tokens back
    expect(buckets.take("k", 200)).toBe(true)
    expect(buckets.take("k", 200)).toBe(true)
    expect(buckets.take("k", 200)).toBe(false)
  })

  it("never refills past capacity", () => {
    const buckets = new TokenBuckets(parse("2/s"))
    buckets.take("k", 0)
    const results = [0, 0, 0].map(() => buckets.take("k", 60_000))
    expect(results).toEqual([true, true, false])
  })

  it("keeps one bucket per key and forgets a player's buckets by prefix", () => {
    const buckets = new TokenBuckets(parse("1/s"))
    expect(buckets.take("1|a", 0)).toBe(true)
    expect(buckets.take("1|a", 0)).toBe(false)
    expect(buckets.take("2|a", 0)).toBe(true)
    expect(buckets.take("1|b", 0)).toBe(true)
    buckets.deletePrefix("1|")
    expect(buckets.size).toBe(1)
    expect(buckets.take("1|a", 0)).toBe(true)
  })
})
