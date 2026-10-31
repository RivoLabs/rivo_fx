/**
 * A stand-in for the FiveM JS runtime's globals: events, net events, convars
 * and the handful of natives Rivo FX calls. Installed onto `globalThis`.
 */
import { Effect } from "effect"

type Listener = (...args: Array<any>) => void

export interface Sent {
  readonly event: string
  readonly target?: number | string
  readonly payload: any
}

export class FiveMMock {
  readonly listeners = new Map<string, Set<Listener>>()
  /** `TriggerClientEvent` calls. */
  readonly toClients: Array<Sent> = []
  /** `TriggerServerEvent` calls. */
  readonly toServer: Array<Sent> = []
  /** `TriggerEvent` / `emit` calls. */
  readonly local: Array<{ readonly event: string; readonly args: Array<any> }> = []
  readonly convars = new Map<string, string>()
  readonly natives: Record<string, (...args: Array<any>) => any> = {}
  readonly printed: Array<string> = []

  constructor(readonly resource = "test_res", readonly server = true) {}

  install(): this {
    const g = globalThis as any
    const add = (event: string, fn: Listener) => {
      let set = this.listeners.get(event)
      if (!set) this.listeners.set(event, (set = new Set()))
      set.add(fn)
    }
    Object.assign(g, {
      on: add,
      onNet: add,
      AddEventHandler: add,
      removeEventListener: (event: string, fn: Listener) => this.listeners.get(event)?.delete(fn),
      emit: (event: string, ...args: Array<any>) => {
        this.local.push({ event, args })
        this.dispatch(event, "", args)
      },
      TriggerClientEvent: (event: string, target: number | string, payload: any) =>
        this.toClients.push({ event, target, payload }),
      TriggerServerEvent: (event: string, payload: any) => this.toServer.push({ event, payload }),
      GetConvar: (name: string, fallback: string) => this.convars.get(name) ?? fallback,
      GetCurrentResourceName: () => this.resource,
      IsDuplicityVersion: () => this.server,
      source: undefined,
      ...this.natives
    })
    return this
  }

  /** Defines (or replaces) natives on the global object. */
  native(fns: Record<string, (...args: Array<any>) => any>): this {
    Object.assign(this.natives, fns)
    Object.assign(globalThis, fns)
    return this
  }

  dispatch(event: string, source: number | string, args: Array<any>): void {
    const g = globalThis as any
    for (const fn of [...(this.listeners.get(event) ?? [])]) {
      g.source = source
      try {
        fn(...args)
      } finally {
        g.source = undefined
      }
    }
  }

  /** A net event from `player` to this server. */
  fromClient(player: number, event: string, ...args: Array<any>): void {
    this.dispatch(event, player, args)
  }

  /** A net event from the server to this client. */
  fromServer(event: string, ...args: Array<any>): void {
    this.dispatch(event, 65535, args)
  }

  listenerCount(event: string): number {
    return this.listeners.get(event)?.size ?? 0
  }
}

/** Lets forked fibers run: yields to the scheduler a few times. */
export const settle = Effect.gen(function*() {
  for (let i = 0; i < 20; i++) yield* Effect.yieldNow
})
