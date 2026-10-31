import { describe, expect, it } from "@effect/vitest"
import { Effect, Layer, PubSub, Schema, Scope, Exit } from "effect"
import { TestClock } from "effect/testing"
import { beforeEach } from "vitest"
import * as Net from "../../src/server/Net.js"
import { RateLimiter } from "../../src/server/RateLimiter.js"
import { SecurityEvents } from "../../src/server/SecurityEvents.js"
import { FiveMMock, settle } from "../support/fivem-mock.js"

let fivem: FiveMMock
beforeEach(() => {
  fivem = new FiveMMock("shop").install()
})

const ServerLayer = Layer.mergeAll(SecurityEvents.layer, RateLimiter.layer)
const Buy = Schema.Struct({ item: Schema.String, amount: Schema.Int })

describe("Net.handle", () => {
  it.effect("runs the handler with the player and the decoded payload", () =>
    Effect.gen(function*() {
      const seen: Array<[number, unknown]> = []
      yield* Net.handle("shop:buy", Buy, (source, input) => Effect.sync(() => seen.push([source, input])))
      fivem.fromClient(7, "shop:buy", { item: "bread", amount: 2 })
      yield* settle
      expect(seen).toEqual([[7, { item: "bread", amount: 2 }]])
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("rejects an invalid payload with a SecurityEvent and never runs the handler", () =>
    Effect.gen(function*() {
      const events = yield* SecurityEvents.use((s) => s.subscribe)
      let ran = false
      yield* Net.handle("shop:buy", Buy, () => Effect.sync(() => (ran = true)))
      fivem.fromClient(3, "shop:buy", { item: "bread", amount: "lots" })
      yield* settle
      expect(ran).toBe(false)
      const event = yield* PubSub.take(events)
      expect(event).toMatchObject({ kind: "invalid_payload", source: 3, name: "shop:buy" })
      expect(event.message).toContain("amount")
      // mirrored to every resource with TriggerEvent("rivo_fx:security", event, resourceName)
      const mirrored = fivem.local.find((e) => e.event === "rivo_fx:security")
      expect(mirrored?.args).toEqual([event, "shop"])
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("rate limits per player and event (10/s by default) with a token bucket", () =>
    Effect.gen(function*() {
      const events = yield* SecurityEvents.use((s) => s.subscribe)
      const counts = new Map<number, number>()
      yield* Net.handle("ping", Schema.Number, (source) =>
        Effect.sync(() => counts.set(source, (counts.get(source) ?? 0) + 1)))

      for (let i = 0; i < 12; i++) fivem.fromClient(1, "ping", i)
      fivem.fromClient(2, "ping", 0)
      yield* settle
      expect(counts.get(1)).toBe(10)
      expect(counts.get(2)).toBe(1)
      const limited = yield* PubSub.takeAll(events)
      expect(limited).toHaveLength(2)
      expect(limited[0]).toEqual({ kind: "rate_limited", source: 1, name: "ping" })

      // one token back every 100 ms
      yield* TestClock.adjust("100 millis")
      fivem.fromClient(1, "ping", 0)
      fivem.fromClient(1, "ping", 0)
      yield* settle
      expect(counts.get(1)).toBe(11)
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("honours a custom limit and rateLimit: false", () =>
    Effect.gen(function*() {
      let limited = 0
      let unlimited = 0
      yield* Net.handle("a", Schema.Unknown, () => Effect.sync(() => limited++), { rateLimit: "2/m" })
      yield* Net.handle("b", Schema.Unknown, () => Effect.sync(() => unlimited++), { rateLimit: false })
      for (let i = 0; i < 50; i++) {
        fivem.fromClient(1, "a", i)
        fivem.fromClient(1, "b", i)
      }
      yield* settle
      expect(limited).toBe(2)
      expect(unlimited).toBe(50)
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("removes the listener and interrupts running handlers when its scope closes", () =>
    Effect.gen(function*() {
      const scope = yield* Scope.make()
      let interrupted = false
      yield* Net.handle("slow", Schema.Unknown, () =>
        Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => (interrupted = true))))).pipe(
          Scope.provide(scope)
        )
      fivem.fromClient(1, "slow", null)
      yield* settle
      expect(fivem.listenerCount("slow")).toBe(1)
      yield* Scope.close(scope, Exit.void)
      expect(fivem.listenerCount("slow")).toBe(0)
      expect(interrupted).toBe(true)
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("ignores a local TriggerEvent with no player source", () =>
    Effect.gen(function*() {
      let ran = false
      yield* Net.handle("x", Schema.Unknown, () => Effect.sync(() => (ran = true)))
      ;(globalThis as any).emit("x", 1)
      yield* settle
      expect(ran).toBe(false)
    }).pipe(Effect.provide(ServerLayer)))
})

describe("Net emit helpers", () => {
  it.effect("emitClient and broadcast use TriggerClientEvent with one payload argument", () =>
    Effect.gen(function*() {
      yield* Net.emitClient("hud:money", 4, { cash: 10 })
      yield* Net.broadcast("weather", "rain")
      expect(fivem.toClients).toEqual([
        { event: "hud:money", target: 4, payload: { cash: 10 } },
        { event: "weather", target: -1, payload: "rain" }
      ])
    }))
})
