import { Cause, Effect, Formatter, Layer, Logger as EffectLogger, LogLevel, References } from "effect"

/** Convar that sets the minimum log level, e.g. `set rivo_fx:logLevel Debug`. */
export const LOG_LEVEL_CONVAR = "rivo_fx:logLevel"

/** FiveM console color codes per level. */
export const colors: Record<LogLevel.LogLevel, string> = {
  All: "^7",
  Fatal: "^8",
  Error: "^1",
  Warn: "^3",
  Info: "^5",
  Debug: "^6",
  Trace: "^9",
  None: "^7"
}

/** Parses a level name case-insensitively (`"debug"`, `"WARN"`). */
export const parseLogLevel = (value: string): LogLevel.LogLevel | undefined => {
  const lower = value.trim().toLowerCase()
  return LogLevel.values.find((level) => level.toLowerCase() === lower)
}

const formatMessage = (message: unknown): string => {
  const parts = Array.isArray(message) ? message : [message]
  return parts.map((part) => (typeof part === "string" ? part : Formatter.format(part))).join(" ")
}

/** Formats one log line: `^5[INFO]^7 message`, with the cause appended when there is one. */
export const formatLine = (options: EffectLogger.Options<unknown>): string => {
  let line = `${colors[options.logLevel]}[${options.logLevel.toUpperCase()}]^7 ${formatMessage(options.message)}`
  if (options.cause.reasons.length > 0) {
    line += `\n${colors[options.logLevel]}${Cause.pretty(options.cause)}^7`
  }
  return line
}

/**
 * An Effect logger that prints through FiveM's console with color codes.
 * FiveM already prefixes each line with the resource name. Every level goes
 * through `console.log`, because FiveM's `console.warn` / `console.error` add
 * their own "Warning:" / "Error:" prefix on top of the level tag.
 */
export const fivemLogger: EffectLogger.Logger<unknown, void> = EffectLogger.make((options) => {
  console.log(formatLine(options))
})

/** The level named by the `rivo_fx:logLevel` convar, `Info` when unset or invalid. */
export const convarLogLevel = (): LogLevel.LogLevel =>
  parseLogLevel(GetConvar(LOG_LEVEL_CONVAR, "Info")) ?? "Info"

/**
 * Replaces the default logger with {@link fivemLogger} and sets the minimum
 * level from the `rivo_fx:logLevel` convar.
 */
export const layer: Layer.Layer<never> = Layer.mergeAll(
  EffectLogger.layer([fivemLogger]),
  Layer.effect(References.MinimumLogLevel, Effect.sync(convarLogLevel))
)
