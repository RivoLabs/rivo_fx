import { describe, expect, it } from "@effect/vitest"
import { Data, Effect, Fiber, Layer, PubSub, Schema } from "effect"
import { beforeEach } from "vitest"
import { RateLimiter } from "../../src/server/RateLimiter.js"
import * as Rpc from "../../src/server/Rpc.js"
import { SecurityEvents } from "../../src/server/SecurityEvents.js"
import { FiveMMock, settle } from "../support/fivem-mock.js"

let fivem: FiveMMock
beforeEach(() => {
  fivem = new FiveMMock("bank").install()
})

const ServerLayer = Rpc.RpcServer.layer.pipe(Layer.provideMerge(Layer.mergeAll(SecurityEvents.layer, RateLimiter.layer)))

class NotEnoughMoney extends Data.TaggedError("NotEnoughMoney")<{ readonly balance: number; readonly wanted: number }> {}

const Withdraw = Schema.Struct({ amount: Schema.Int })
const withdraw = Rpc.register("bank:withdraw", { input: Withdraw, output: Schema.Number }, (source, { amount }) =>
  amount > 100 ? Effect.fail(new NotEnoughMoney({ balance: 100, wanted: amount })) : Effect.succeed(100 - amount + source))

/** A client request exactly as a Lua or JS caller sends it. */
const request = (player: number, id: number, name: string, input: unknown, from = "bank") =>
  fivem.fromClient(player, "__rfx:bank:req", { id, name, from, input })

describe("Rpc.register (client → server host)", () => {
  it.effect("answers a success to __rfx:<from>:res for that player", () =>
    Effect.gen(function*() {
      yield* withdraw
      request(5, 1, "bank:withdraw", { amount: 30 })
      yield* settle
      expect(fivem.toClients).toEqual([{ event: "__rfx:bank:res", target: 5, payload: { id: 1, ok: true, value: 75 } }])
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("runs the handler in a span that continues the request's trace", () =>
    Effect.gen(function*() {
      yield* Rpc.register("whoami", { input: Schema.Unknown }, () =>
        Effect.map(Effect.currentSpan, (span) => ({
          traceId: span.traceId,
          parent: span.parent._tag === "Some" ? span.parent.value.spanId : null
        })))
      fivem.fromClient(5, "__rfx:bank:req", {
        id: 1, name: "whoami", from: "bank", input: null,
        trace: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
      })
      fivem.fromClient(5, "__rfx:bank:req", { id: 2, name: "whoami", from: "bank", input: null, trace: "garbage" })
      yield* settle
      expect(fivem.toClients[0]?.payload).toEqual({
        id: 1, ok: true, value: { traceId: "0af7651916cd43dd8448eb211c80319c", parent: "b7ad6b7169203331" }
      })
      const fresh = fivem.toClients[1]?.payload as { value: { traceId: string; parent: string | null } }
      expect(fresh.value.traceId).not.toBe("0af7651916cd43dd8448eb211c80319c")
      expect(fresh.value.parent).toBeNull()
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("sends a tagged error with its _tag and fields", () =>
    Effect.gen(function*() {
      yield* withdraw
      request(5, 2, "bank:withdraw", { amount: 500 }, "other_res")
      yield* settle
      expect(fivem.toClients).toEqual([{
        event: "__rfx:other_res:res",
        target: 5,
        payload: { id: 2, ok: false, error: { _tag: "NotEnoughMoney", balance: 100, wanted: 500 } }
      }])
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("turns defects into RpcInternalError without leaking details", () =>
    Effect.gen(function*() {
      yield* Rpc.register("boom", { input: Schema.Unknown }, () => Effect.die(new Error("db password is hunter2")))
      request(1, 3, "boom", null)
      yield* settle
      expect(fivem.toClients[0]?.payload).toEqual({ id: 3, ok: false, error: { _tag: "RpcInternalError", name: "boom" } })
      expect(JSON.stringify(fivem.toClients)).not.toContain("hunter2")
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("answers RpcNotFound and publishes unknown_rpc", () =>
    Effect.gen(function*() {
      const events = yield* SecurityEvents.use((s) => s.subscribe)
      request(9, 4, "nope", {})
      yield* settle
      expect(fivem.toClients[0]?.payload).toEqual({ id: 4, ok: false, error: { _tag: "RpcNotFound", name: "nope" } })
      expect(yield* PubSub.take(events)).toEqual({ kind: "unknown_rpc", source: 9, name: "nope" })
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("answers RpcInvalidInput, publishes invalid_payload and never runs the handler", () =>
    Effect.gen(function*() {
      const events = yield* SecurityEvents.use((s) => s.subscribe)
      let ran = false
      yield* Rpc.register("bank:withdraw", { input: Withdraw }, () => Effect.sync(() => (ran = true)))
      request(2, 5, "bank:withdraw", { amount: "all of it" })
      yield* settle
      expect(ran).toBe(false)
      const payload = fivem.toClients[0]?.payload
      expect(payload).toMatchObject({ id: 5, ok: false, error: { _tag: "RpcInvalidInput", name: "bank:withdraw" } })
      expect(typeof payload.error.message).toBe("string")
      const event = yield* PubSub.take(events)
      expect(event).toMatchObject({ kind: "invalid_payload", source: 2, name: "bank:withdraw" })
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("answers RpcRateLimited past the limit and publishes rate_limited", () =>
    Effect.gen(function*() {
      const events = yield* SecurityEvents.use((s) => s.subscribe)
      yield* Rpc.register("cheap", { input: Schema.Unknown, rateLimit: "2/s" }, () => Effect.succeed("ok"))
      for (let id = 1; id <= 3; id++) request(1, id, "cheap", null)
      yield* settle
      expect(fivem.toClients.map((s) => s.payload.ok)).toEqual([true, true, false])
      expect(fivem.toClients[2]?.payload.error).toEqual({ _tag: "RpcRateLimited", name: "cheap" })
      expect(yield* PubSub.take(events)).toEqual({ kind: "rate_limited", source: 1, name: "cheap" })
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("interrupts the handler on cancel and sends no response", () =>
    Effect.gen(function*() {
      let interrupted = false
      yield* Rpc.register("slow", { input: Schema.Unknown }, () =>
        Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => (interrupted = true)))))
      request(4, 11, "slow", null)
      yield* settle
      // a cancel from another player for the same id does nothing
      fivem.fromClient(5, "__rfx:bank:cancel", { id: 11, from: "bank" })
      yield* settle
      expect(interrupted).toBe(false)
      fivem.fromClient(4, "__rfx:bank:cancel", { id: 11, from: "bank" })
      yield* settle
      expect(interrupted).toBe(true)
      expect(fivem.toClients).toEqual([])
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("answers RpcInternalError when a tagged failure comes with a defect", () =>
    Effect.gen(function*() {
      yield* Rpc.register("mixed", { input: Schema.Unknown }, () =>
        Effect.fail(new NotEnoughMoney({ balance: 1, wanted: 2 })).pipe(Effect.ensuring(Effect.die("finalizer bug"))))
      request(2, 13, "mixed", null)
      yield* settle
      expect(fivem.toClients[0]?.payload.error).toEqual({ _tag: "RpcInternalError", name: "mixed" })
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("interrupts the handler when the calling player drops", () =>
    Effect.gen(function*() {
      let interrupted = false
      yield* Rpc.register("slow", { input: Schema.Unknown }, () =>
        Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => (interrupted = true)))))
      request(4, 12, "slow", null)
      yield* settle
      fivem.fromClient(5, "playerDropped", "Exiting") // someone else leaving changes nothing
      yield* settle
      expect(interrupted).toBe(false)
      fivem.fromClient(4, "playerDropped", "Exiting")
      yield* settle
      expect(interrupted).toBe(true)
      expect(fivem.toClients).toEqual([])
    }).pipe(Effect.provide(ServerLayer)))

  it.effect("publishes invalid_payload for a malformed request envelope", () =>
    Effect.gen(function*() {
      const events = yield* SecurityEvents.use((s) => s.subscribe)
      fivem.fromClient(6, "__rfx:bank:req", "not a request")
      yield* settle
      expect(yield* PubSub.take(events)).toMatchObject({ kind: "invalid_payload", source: 6, name: "__rfx:bank:req" })
      expect(fivem.toClients).toEqual([])
    }).pipe(Effect.provide(ServerLayer)))
})

describe("Rpc.callClient (server → client caller)", () => {
  it.effect("sends the request to the player and matches the response on (source, id)", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Rpc.callClient(3, "ui:confirm", { text: "Sure?" }, { output: Schema.Boolean }))
      yield* settle
      expect(fivem.toClients).toEqual([
        {
          event: "__rfx:bank:req",
          target: 3,
          payload: { id: 1, name: "ui:confirm", from: "bank", input: { text: "Sure?" }, trace: expect.stringMatching(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/) }
        }
      ])
      // another player cannot answer player 3's call
      fivem.fromClient(4, "__rfx:bank:res", { id: 1, ok: true, value: false })
      fivem.fromClient(3, "__rfx:bank:res", { id: 1, ok: true, value: true })
      expect(yield* Fiber.join(fiber)).toBe(true)
    }).pipe(Effect.provide(ServerLayer)))
})
