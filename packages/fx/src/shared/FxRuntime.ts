import { Cause, Effect, Exit, Layer, ManagedRuntime, Scheduler } from "effect"
import { resourceName } from "./fivem.js"

/**
 * A scheduler whose fibers all share one dispatcher, so pending work can be
 * flushed synchronously.
 *
 * FiveM tears a resource's JS context down right after `onResourceStop`, and
 * a task queued with `setImmediate` at that point may never run. Disposing the
 * runtime and then flushing this scheduler interrupts fibers and runs
 * finalizers inside the `onResourceStop` handler itself.
 */
export class FlushableScheduler implements Scheduler.Scheduler {
  readonly executionMode = "async" as const
  readonly #inner = new Scheduler.MixedScheduler()
  readonly #dispatcher = this.#inner.makeDispatcher()

  shouldYield(fiber: Parameters<Scheduler.Scheduler["shouldYield"]>[0]) {
    return this.#inner.shouldYield(fiber)
  }

  makeDispatcher(): Scheduler.SchedulerDispatcher {
    return this.#dispatcher
  }

  /** Runs every queued task, including tasks queued while flushing. */
  flush(): void {
    this.#dispatcher.flush()
  }
}

/** A resource-level `ManagedRuntime` that disposes itself when its resource stops. */
export interface FxRuntime<R, E> extends ManagedRuntime.ManagedRuntime<R, E> {
  /** Disposes the runtime now and flushes pending work synchronously. */
  readonly stop: () => void
}

export interface FxRuntimeOptions {
  /** Resource whose `onResourceStop` disposes the runtime. Defaults to the current resource. */
  readonly resource?: string
}

/**
 * Builds a `ManagedRuntime` for this resource from `layer`.
 *
 * The layer is built synchronously, as far as it can go without waiting
 * (failures are logged), and the runtime is
 * disposed on `onResourceStop` for the current resource: every fiber forked
 * in its scope is interrupted and every finalizer runs before the resource
 * goes away.
 *
 * ```ts
 * const Main = Layer.effectDiscard(Effect.gen(function* () {
 *   yield* Net.handle("shop:buy", BuyInput, (source, input) => buy(source, input))
 * }))
 * export const runtime = FxRuntime.make(Main.pipe(Layer.provideMerge(FxServer.layer)))
 * ```
 */
export const make = <R, E>(layer: Layer.Layer<R, E, never>, options: FxRuntimeOptions = {}): FxRuntime<R, E> => {
  const resource = options.resource ?? resourceName()
  const scheduler = new FlushableScheduler()
  const managed = ManagedRuntime.make(
    layer.pipe(Layer.provideMerge(Layer.succeed(Scheduler.Scheduler, scheduler)))
  ) as unknown as ManagedRuntime.ManagedRuntime<R, E>

  let stopped = false
  const stop = (): void => {
    if (stopped) return
    stopped = true
    removeEventListener("onResourceStop", onResourceStop)
    Effect.runFork(managed.disposeEffect, { scheduler })
    scheduler.flush()
  }
  const onResourceStop = (name: string): void => {
    if (name === resource) stop()
  }
  on("onResourceStop", onResourceStop)

  const build = Effect.runFork(managed.contextEffect, { scheduler })
  build.addObserver((exit) => {
    if (Exit.isFailure(exit) && !Cause.hasInterruptsOnly(exit.cause)) {
      console.error(`^1[rivo_fx] failed to start the runtime:^7\n${Cause.pretty(exit.cause)}`)
    }
  })
  // Build as far as possible right now, so net handlers and RPCs are
  // registered before the resource's script finishes loading.
  scheduler.flush()

  return Object.assign(managed, { stop })
}
