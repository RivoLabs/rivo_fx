import { describe, expect, it } from "@effect/vitest"
import { Effect, Exit, Fiber, Schema, Tracer } from "effect"
import { TestClock } from "effect/testing"
import { beforeEach } from "vitest"
import * as Rpc from "../../src/client/Rpc.js"
import { RemoteError, RpcInvalidOutput, RpcNotFound, RpcTimeout } from "../../src/shared/errors.js"
import { FiveMMock, settle } from "../support/fivem-mock.js"

let fivem: FiveMMock
beforeEach(() => {
  fivem = new FiveMMock("bank", false).install()
})

class NotEnoughMoney extends Schema.TaggedError<NotEnoughMoney>()("NotEnoughMoney", {
  balance: Schema.Number,
  wanted: Schema.Number
}) {}

/** The server answering the most recent request, exactly as a Lua or JS host does. */
const respond = (response: Record<string, unknown>) => {
  const last = fivem.toServer.at(-1)!
  fivem.fromServer(`__rfx:${last.payload.from}:res`, { id: last.payload.id, ...response })
}

describe("Rpc.call (client → server caller)", () => {
  it.effect("sends { id, name, from, input, trace } to __rfx:<res>:req and returns the value", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Rpc.call("bank:balance", { account: 1 }, { output: Schema.Number }))
      yield* settle
      expect(fivem.toServer).toEqual([{
        event: "__rfx:bank:req",
        payload: { id: 1, name: "bank:balance", from: "bank", input: { account: 1 }, trace: expect.stringMatching(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/) }
      }])
      respond({ ok: true, value: 250 })
      expect(yield* Fiber.join(fiber)).toBe(250)
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("the request's trace continues the caller's span", () =>
    Effect.gen(function*() {
      const parent = Tracer.externalSpan({ traceId: "0af7651916cd43dd8448eb211c80319c", spanId: "b7ad6b7169203331" })
      yield* Effect.forkChild(Rpc.call("x", null).pipe(Effect.withSpan("open bank", { parent })))
      yield* settle
      const [, traceId, spanId] = (fivem.toServer[0]?.payload.trace as string).split("-")
      expect(traceId).toBe("0af7651916cd43dd8448eb211c80319c")
      expect(spanId).not.toBe("b7ad6b7169203331") // the rpc.client span, two levels below
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("targets another resource with `resource`", () =>
    Effect.gen(function*() {
      yield* Effect.forkChild(Rpc.call("x", null, { resource: "core" }))
      yield* settle
      expect(fivem.toServer[0]?.event).toBe("__rfx:core:req")
      expect(fivem.toServer[0]?.payload.from).toBe("bank")
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("rebuilds a tagged error so catchTag works on the caller", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(
        Rpc.call("bank:withdraw", { amount: 500 }).pipe(
          Effect.catchTag("NotEnoughMoney", (e) => Effect.succeed(`short by ${(e.wanted as number) - (e.balance as number)}`))
        )
      )
      yield* settle
      respond({ ok: false, error: { _tag: "NotEnoughMoney", balance: 100, wanted: 500 } })
      expect(yield* Fiber.join(fiber)).toBe("short by 400")
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("rebuilds unknown tags as RemoteError and known ones with `errors`", () =>
    Effect.gen(function*() {
      const plain = yield* Effect.forkChild(Effect.flip(Rpc.call("a", null)))
      yield* settle
      respond({ ok: false, error: { _tag: "NotEnoughMoney", balance: 1, wanted: 2 } })
      const remote = yield* Fiber.join(plain)
      expect(remote).toBeInstanceOf(RemoteError)
      expect(remote).toMatchObject({ _tag: "NotEnoughMoney", balance: 1, wanted: 2 })

      const typed = yield* Effect.forkChild(Effect.flip(Rpc.call("a", null, { errors: NotEnoughMoney })))
      yield* settle
      respond({ ok: false, error: { _tag: "NotEnoughMoney", balance: 1, wanted: 2 } })
      const error = yield* Fiber.join(typed)
      expect(error).toBeInstanceOf(NotEnoughMoney)
      expect(error).toMatchObject({ balance: 1, wanted: 2 })
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("rebuilds protocol errors as their own classes", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Effect.flip(Rpc.call("missing", null)))
      yield* settle
      respond({ ok: false, error: { _tag: "RpcNotFound", name: "missing" } })
      const error = yield* Fiber.join(fiber)
      expect(error).toBeInstanceOf(RpcNotFound)
      expect(error).toMatchObject({ _tag: "RpcNotFound", name: "missing" })
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("fails with RpcInvalidOutput when the value does not match `output`", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Effect.flip(Rpc.call("n", null, { output: Schema.Number })))
      yield* settle
      respond({ ok: true, value: "not a number" })
      const error = yield* Fiber.join(fiber)
      expect(error).toBeInstanceOf(RpcInvalidOutput)
      expect(error).toMatchObject({ name: "n" })
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("times out with RpcTimeout and sends the cancel event", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Effect.flip(Rpc.call("slow", null, { timeout: 2_000 })))
      yield* settle
      yield* TestClock.adjust("1999 millis")
      expect(fivem.toServer).toHaveLength(1)
      yield* TestClock.adjust("1 millis")
      const error = yield* Fiber.join(fiber)
      expect(error).toBeInstanceOf(RpcTimeout)
      expect(error).toMatchObject({ _tag: "RpcTimeout", name: "slow", timeoutMs: 2_000 })
      expect(fivem.toServer[1]).toEqual({ event: "__rfx:bank:cancel", payload: { id: 1, from: "bank" } })
      // a late response is ignored
      fivem.fromServer("__rfx:bank:res", { id: 1, ok: true, value: 1 })
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("sends the cancel event when the calling fiber is interrupted", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Rpc.call("slow", null, { resource: "core" }))
      yield* settle
      yield* Fiber.interrupt(fiber)
      expect(fivem.toServer[1]).toEqual({ event: "__rfx:core:cancel", payload: { id: 1, from: "bank" } })
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))

  it.effect("does not send a cancel after the response arrived", () =>
    Effect.gen(function*() {
      const exit = yield* Effect.forkChild(Rpc.call("a", null)).pipe(
        Effect.tap(() => settle),
        Effect.tap(() => Effect.sync(() => respond({ ok: true, value: 1 }))),
        Effect.flatMap(Fiber.await)
      )
      expect(Exit.isSuccess(exit)).toBe(true)
      expect(fivem.toServer).toHaveLength(1)
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))
})

describe("Rpc.register on the client (server → client host)", () => {
  it.effect("answers the server with TriggerServerEvent", () =>
    Effect.gen(function*() {
      yield* Rpc.register("ui:confirm", { input: Schema.Struct({ text: Schema.String }) }, ({ text }) =>
        Effect.succeed(text.length > 3))
      fivem.fromServer("__rfx:bank:req", { id: 7, name: "ui:confirm", from: "bank", input: { text: "Sure?" } })
      yield* settle
      expect(fivem.toServer).toEqual([{ event: "__rfx:bank:res", payload: { id: 7, ok: true, value: true } }])
    }).pipe(Effect.provide(Rpc.RpcClient.layer)))
})
