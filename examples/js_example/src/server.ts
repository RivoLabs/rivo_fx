import { Effect, Layer, Schema, Stream } from "effect"
import { FxRuntime, FxServer, Net, Rpc, SecurityEvents, type SecurityEvent } from "@rivolabs/fx/server"
import { Deposit, NotEnoughMoney, Withdraw } from "./shared"

const balances = new Map<number, number>()
const balanceOf = (player: number) => balances.get(player) ?? 0

/** Read by the e2e test through the harness. */
const state = {
  deposits: [] as Array<{ source: number; amount: number }>,
  security: [] as Array<SecurityEvent>,
  slowStarted: 0,
  slowInterrupted: 0,
  clientAnswers: [] as Array<unknown>
}
;(globalThis as any).jsExample = state

const Main = Layer.effectDiscard(Effect.gen(function*() {
  // A validated, rate-limited (10/s per player by default) net event.
  yield* Net.handle("js_example:deposit", Deposit, (source, { amount }) =>
    Effect.gen(function*() {
      balances.set(source, balanceOf(source) + amount)
      state.deposits.push({ source, amount })
      yield* Effect.log(`player ${source} deposited ${amount}`)
      yield* Net.emitClient("js_example:balance", source, balanceOf(source))
    }))

  // Client → server RPC whose tagged error crosses the wire.
  yield* Rpc.register("js_example:withdraw", { input: Withdraw, output: Schema.Number }, (source, { amount }) =>
    Effect.gen(function*() {
      const balance = balanceOf(source)
      if (amount > balance) return yield* new NotEnoughMoney({ balance, wanted: amount })
      balances.set(source, balance - amount)
      return balance - amount
    }))

  // A handler that never finishes, to show cancellation: the client times out,
  // sends the cancel event, and this fiber is interrupted.
  yield* Rpc.register("js_example:slow", { input: Schema.Unknown }, () =>
    Effect.sync(() => state.slowStarted++).pipe(
      Effect.andThen(Effect.never),
      Effect.onInterrupt(() => Effect.sync(() => state.slowInterrupted++))
    ))

  // Server → client RPC, triggered by a net event.
  yield* Net.handle("js_example:askClient", Schema.Struct({ question: Schema.String }), (source, { question }) =>
    Rpc.callClient(source, "js_example:answer", { question }, { output: Schema.String, timeout: 2_000 }).pipe(
      Effect.tap((answer) => Effect.sync(() => state.clientAnswers.push(answer)))
    ))

  // Every rejected payload or rate-limit hit, inside this resource.
  yield* SecurityEvents.stream.pipe(
    Stream.runForEach((event) => Effect.sync(() => state.security.push(event))),
    Effect.forkScoped
  )
}))

FxRuntime.make(Main.pipe(Layer.provide(FxServer.layer)))
