import { describe, expect, it } from "@effect/vitest"
import { Config, Effect, Logger as EffectLogger, References } from "effect"
import { beforeEach } from "vitest"
import * as FxConfig from "../../src/shared/Config.js"
import * as FxLogger from "../../src/shared/Logger.js"
import { FiveMMock } from "../support/fivem-mock.js"

let fivem: FiveMMock
beforeEach(() => {
  fivem = new FiveMMock("cfg").install()
})

describe("convar ConfigProvider", () => {
  it.effect("reads Config.integer from a convar", () =>
    Effect.gen(function*() {
      fivem.convars.set("my_max", "32")
      expect(yield* FxConfig.integer("my_max")).toBe(32)
      expect(yield* Config.Int("my_max")).toBe(32)
    }).pipe(Effect.provide(FxConfig.layer())))

  it.effect("treats an unset convar as missing, so defaults and options work", () =>
    Effect.gen(function*() {
      expect(yield* Config.String("nope").pipe(Config.withDefault("fallback"))).toBe("fallback")
      const error = yield* Effect.flip(FxConfig.string("nope"))
      expect(String(error)).toContain("nope")
    }).pipe(Effect.provide(FxConfig.layer())))

  it.effect("fails on a convar that does not parse", () =>
    Effect.gen(function*() {
      fivem.convars.set("my_max", "lots")
      const exit = yield* Effect.exit(FxConfig.integer("my_max"))
      expect(exit._tag).toBe("Failure")
    }).pipe(Effect.provide(FxConfig.layer())))

  it.effect("joins nested paths with ':' (or a custom separator)", () =>
    Effect.gen(function*() {
      fivem.convars.set("my_res:debug", "true")
      fivem.convars.set("my_res_debug", "false")
      expect(yield* Config.Boolean("debug").pipe(Config.nested("my_res"))).toBe(true)
      const underscored = yield* Config.Boolean("debug").pipe(Config.nested("my_res")).pipe(
        Effect.provide(FxConfig.layer({ separator: "_" }))
      )
      expect(underscored).toBe(false)
    }).pipe(Effect.provide(FxConfig.layer())))

  it.effect("reads structs field by field", () =>
    Effect.gen(function*() {
      fivem.convars.set("shop:tax", "0.2")
      fivem.convars.set("shop:name", "Corner")
      const shop = yield* Config.all({ tax: Config.Number("tax"), name: Config.String("name") }).pipe(
        Config.nested("shop")
      )
      expect(shop).toEqual({ tax: 0.2, name: "Corner" })
    }).pipe(Effect.provide(FxConfig.layer())))
})

describe("FiveM logger", () => {
  it("parses level names case-insensitively", () => {
    expect(FxLogger.parseLogLevel("debug")).toBe("Debug")
    expect(FxLogger.parseLogLevel(" WARN ")).toBe("Warn")
    expect(FxLogger.parseLogLevel("loud")).toBeUndefined()
  })

  it.effect("sets the minimum level from rivo_fx:logLevel", () =>
    Effect.gen(function*() {
      fivem.convars.set("rivo_fx:logLevel", "debug")
      const level = yield* References.MinimumLogLevel.pipe(Effect.provide(FxLogger.layer))
      expect(level).toBe("Debug")
      fivem.convars.delete("rivo_fx:logLevel")
      expect(yield* References.MinimumLogLevel.pipe(Effect.provide(FxLogger.layer))).toBe("Info")
    }))

  it.effect("prints colored lines through console and filters below the level", () =>
    Effect.gen(function*() {
      fivem.convars.set("rivo_fx:logLevel", "Warn")
      const lines: Array<string> = []
      const original = { log: console.log, warn: console.warn, error: console.error }
      console.log = console.warn = console.error = (line: string) => void lines.push(line)
      try {
        yield* Effect.gen(function*() {
          yield* Effect.logInfo("hidden")
          yield* Effect.logWarning("careful", 3)
          yield* Effect.logError("broken")
        }).pipe(Effect.provide(FxLogger.layer))
      } finally {
        Object.assign(console, original)
      }
      expect(lines).toEqual(["^3[WARN]^7 careful 3", "^1[ERROR]^7 broken"])
    }))

  it("formats a cause after the message", () => {
    const line = FxLogger.formatLine({
      message: ["failed"],
      logLevel: "Error",
      cause: { reasons: [] } as any,
      fiber: undefined as any,
      date: new Date()
    } as EffectLogger.Options<unknown>)
    expect(line).toBe("^1[ERROR]^7 failed")
  })
})
