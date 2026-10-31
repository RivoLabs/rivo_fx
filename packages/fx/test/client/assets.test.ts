import { describe, expect, it } from "@effect/vitest"
import { Effect, Fiber, Scope, Exit } from "effect"
import { TestClock } from "effect/testing"
import { beforeEach } from "vitest"
import * as Assets from "../../src/client/Assets.js"
import * as Entity from "../../src/client/Entity.js"
import { FiveMMock, settle } from "../support/fivem-mock.js"

let fivem: FiveMMock
let loaded: Set<string | number>
let calls: Array<string>

beforeEach(() => {
  loaded = new Set()
  calls = []
  fivem = new FiveMMock("cl", false).install().native({
    GetHashKey: (name: string) => (name === "adder" ? 0xb779a091 : 1),
    IsModelInCdimage: (hash: number) => hash === 0xb779a091,
    IsModelValid: () => true,
    HasModelLoaded: (hash: number) => loaded.has(hash),
    RequestModel: (hash: number) => calls.push(`RequestModel ${hash}`),
    SetModelAsNoLongerNeeded: (hash: number) => calls.push(`SetModelAsNoLongerNeeded ${hash}`),
    DoesAnimDictExist: (dict: string) => dict.startsWith("anim@"),
    HasAnimDictLoaded: (dict: string) => loaded.has(dict),
    RequestAnimDict: (dict: string) => calls.push(`RequestAnimDict ${dict}`),
    RemoveAnimDict: (dict: string) => calls.push(`RemoveAnimDict ${dict}`),
    HasNamedPtfxAssetLoaded: (asset: string) => loaded.has(asset),
    RequestNamedPtfxAsset: (asset: string) => calls.push(`RequestNamedPtfxAsset ${asset}`),
    RemoveNamedPtfxAsset: (asset: string) => calls.push(`RemoveNamedPtfxAsset ${asset}`),
    DoesEntityExist: (entity: number) => entity === 100,
    NetworkHasControlOfEntity: (entity: number) => loaded.has(`control ${entity}`),
    NetworkRequestControlOfEntity: (entity: number) => calls.push(`NetworkRequestControlOfEntity ${entity}`),
    NetworkDoesNetworkIdExist: (netId: number) => loaded.has(`net ${netId}`),
    NetworkGetEntityFromNetworkId: () => 100
  })
})

describe("Assets.model", () => {
  it.effect("requests the model and polls until it has loaded", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Assets.model("adder"))
      yield* settle
      expect(calls).toEqual([`RequestModel ${0xb779a091}`])
      loaded.add(0xb779a091)
      yield* TestClock.adjust("1 millis")
      expect(yield* Fiber.join(fiber)).toBe(0xb779a091)
    }))

  it.effect("fails with InvalidModel for a model that is not in the CD image", () =>
    Effect.gen(function*() {
      const error = yield* Effect.flip(Assets.model("not_a_car"))
      expect(error).toBeInstanceOf(Assets.InvalidModel)
      expect(error).toMatchObject({ _tag: "InvalidModel", model: "not_a_car" })
      expect(calls).toEqual([])
    }))

  it.effect("fails with AssetTimeout and releases the request", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Effect.flip(Assets.model("adder", { timeout: 500 })))
      yield* settle
      yield* TestClock.adjust("500 millis")
      const error = yield* Fiber.join(fiber)
      expect(error).toMatchObject({ _tag: "AssetTimeout", kind: "model", asset: "adder", timeoutMs: 500 })
      expect(calls).toContain(`SetModelAsNoLongerNeeded ${0xb779a091}`)
    }))

  it.effect("the scoped variant calls SetModelAsNoLongerNeeded on release", () =>
    Effect.gen(function*() {
      loaded.add(0xb779a091)
      const scope = yield* Scope.make()
      const hash = yield* Assets.modelScoped("adder").pipe(Scope.provide(scope))
      expect(calls).toEqual([])
      yield* Scope.close(scope, Exit.void)
      expect(calls).toEqual([`SetModelAsNoLongerNeeded ${hash}`])
    }))
})

describe("Assets.animDict / ptfxAsset", () => {
  it.effect("loads an anim dict and fails on one that does not exist", () =>
    Effect.gen(function*() {
      loaded.add("anim@heists")
      expect(yield* Assets.animDict("anim@heists")).toBe("anim@heists")
      const error = yield* Effect.flip(Assets.animDict("missing"))
      expect(error).toMatchObject({ _tag: "InvalidAnimDict", animDict: "missing" })
    }))

  it.effect("scoped ptfx asset is removed on release", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Effect.scoped(Assets.ptfxAssetScoped("core")))
      yield* settle
      loaded.add("core")
      yield* TestClock.adjust("1 millis")
      yield* Fiber.join(fiber)
      expect(calls).toEqual(["RequestNamedPtfxAsset core", "RemoveNamedPtfxAsset core"])
    }))
})

describe("Entity", () => {
  it.effect("requestControl asks until control is granted", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Entity.requestControl(100))
      yield* settle
      yield* TestClock.adjust("2 millis")
      loaded.add("control 100")
      yield* TestClock.adjust("1 millis")
      expect(yield* Fiber.join(fiber)).toBe(100)
      expect(calls.filter((c) => c === "NetworkRequestControlOfEntity 100").length).toBeGreaterThan(0)
    }))

  it.effect("requestControl fails with EntityNotFound or EntityTimeout", () =>
    Effect.gen(function*() {
      expect(yield* Effect.flip(Entity.requestControl(5))).toMatchObject({ _tag: "EntityNotFound", entity: 5 })
      const fiber = yield* Effect.forkChild(Effect.flip(Entity.requestControl(100, { timeout: 50 })))
      yield* settle
      yield* TestClock.adjust("50 millis")
      expect(yield* Fiber.join(fiber)).toMatchObject({ _tag: "EntityTimeout", operation: "requestControl", id: 100 })
    }))

  it.effect("fromNetId waits for the network id to exist", () =>
    Effect.gen(function*() {
      const fiber = yield* Effect.forkChild(Entity.fromNetId(7))
      yield* settle
      loaded.add("net 7")
      yield* TestClock.adjust("1 millis")
      expect(yield* Fiber.join(fiber)).toBe(100)
      const late = yield* Effect.forkChild(Effect.flip(Entity.fromNetId(8, { timeout: 100 })))
      yield* settle
      yield* TestClock.adjust("100 millis")
      expect(yield* Fiber.join(late)).toMatchObject({ _tag: "EntityTimeout", operation: "fromNetId", id: 8 })
    }))
})
