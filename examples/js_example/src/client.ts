// FiveM client JS has no TextEncoder; this must load before `effect`.
import "@rivolabs/fx/polyfill"
import { Effect, Layer, Schema } from "effect"
import { FxClient, FxRuntime, Net, Rpc } from "@rivolabs/fx/client"
import { NotEnoughMoney } from "./shared"

/** Read by the e2e test through the harness. */
const state = {
  balance: undefined as number | undefined,
  withdrawn: undefined as number | undefined,
  error: undefined as unknown,
  errorIsClass: false,
  caught: undefined as string | undefined,
  slow: undefined as unknown
}
;(globalThis as any).jsExample = state

const Main = Layer.effectDiscard(Effect.gen(function*() {
  yield* Net.handle("js_example:balance", Schema.Number, (balance) => Effect.sync(() => (state.balance = balance)))

  // The server asks; the client answers through a server → client RPC.
  yield* Rpc.register("js_example:answer", { input: Schema.Struct({ question: Schema.String }) }, ({ question }) =>
    Effect.succeed(`client heard: ${question}`))

  // Run the RPC demo when the server says so.
  yield* Net.handle("js_example:runDemo", Schema.Struct({ withdraw: Schema.Number, tooMuch: Schema.Number }), (demo) =>
    Effect.gen(function*() {
      state.withdrawn = yield* Rpc.call("js_example:withdraw", { amount: demo.withdraw }, { output: Schema.Number })

      const error = yield* Effect.flip(
        Rpc.call("js_example:withdraw", { amount: demo.tooMuch }, { errors: NotEnoughMoney })
      )
      state.error = { ...error, _tag: error._tag }
      state.errorIsClass = error instanceof NotEnoughMoney

      state.caught = yield* Rpc.call("js_example:withdraw", { amount: demo.tooMuch }).pipe(
        Effect.as("no error"),
        Effect.catchTag("NotEnoughMoney", (e) => Effect.succeed(`caught NotEnoughMoney (balance ${e.balance})`))
      )

      const slow = yield* Effect.flip(Rpc.call("js_example:slow", null, { timeout: 500 }))
      state.slow = { ...slow, _tag: slow._tag }
    }))

  // A call that outlives the resource, to show shutdown interrupting the server handler.
  yield* Net.handle("js_example:callSlow", Schema.Struct({ timeout: Schema.Number }), ({ timeout }) =>
    Rpc.call("js_example:slow", null, { timeout }).pipe(Effect.ignore))
}))

FxRuntime.make(Main.pipe(Layer.provide(FxClient.layer)))
