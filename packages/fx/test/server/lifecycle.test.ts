import { describe, expect, it as effectIt } from "@effect/vitest"
import { Context, Effect, Layer } from "effect"
import { beforeEach, it } from "vitest"
import * as PlayerScope from "../../src/server/PlayerScope.js"
import * as FxRuntime from "../../src/shared/FxRuntime.js"
import { FiveMMock, settle } from "../support/fivem-mock.js"

let fivem: FiveMMock
beforeEach(() => {
  fivem = new FiveMMock("life").install()
})

class Counter extends Context.Service<Counter, { readonly value: number }>()("Counter") {}

describe("FxRuntime", () => {
  it("builds the layer and runs finalizers synchronously on onResourceStop", async () => {
    const log: Array<string> = []
    const layer = Layer.effect(
      Counter,
      Effect.acquireRelease(
        Effect.sync(() => {
          log.push("acquired")
          return { value: 42 }
        }),
        () => Effect.sync(() => log.push("released"))
      )
    )
    const runtime = FxRuntime.make(layer)
    expect(await runtime.runPromise(Counter.use((c) => Effect.succeed(c.value)))).toBe(42)

    // a long-running fiber in the runtime is interrupted, and its finalizer runs
    runtime.runFork(Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => log.push("fiber interrupted")))))
    await new Promise<void>((resolve) => setTimeout(() => resolve(), 0))

    fivem.dispatch("onResourceStop", "", ["some_other_resource"])
    expect(log).toEqual(["acquired"])

    fivem.dispatch("onResourceStop", "", ["life"])
    // no awaiting: FiveM tears the context down right after this event
    expect(log).toContain("released")
    expect(fivem.listenerCount("onResourceStop")).toBe(0)
  })

  it("interrupts fibers forked by layers when the resource stops", () => {
    const log: Array<string> = []
    const layer = Layer.effectDiscard(
      Effect.forkScoped(Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => log.push("interrupted")))))
    )
    FxRuntime.make(layer)
    fivem.dispatch("onResourceStop", "", ["life"])
    expect(log).toEqual(["interrupted"])
  })
})

describe("PlayerScope", () => {
  effectIt.effect("closes a player's scope on playerDropped", () =>
    Effect.gen(function*() {
      const log: Array<string> = []
      yield* PlayerScope.addFinalizer(1, Effect.sync(() => log.push("1 cleaned")))
      yield* PlayerScope.addFinalizer(2, Effect.sync(() => log.push("2 cleaned")))
      yield* PlayerScope.fork(1, Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => log.push("1 fiber")))))
      yield* settle
      fivem.fromClient(1, "playerDropped", "Exiting")
      yield* settle
      expect(log.sort()).toEqual(["1 cleaned", "1 fiber"])
      // a new scope is created if the id is reused later
      const again = yield* PlayerScope.get(1)
      expect(again).toBeDefined()
    }).pipe(Effect.provide(PlayerScope.PlayerScopes.layer)))
})
