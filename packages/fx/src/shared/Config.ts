import { Config, ConfigProvider, Effect, Layer } from "effect"

const UNSET = "\u0000rivo_fx:unset"

export interface ConvarProviderOptions {
  /**
   * Joins nested config paths into one convar name. Defaults to `":"`, so
   * `Config.nested(Config.integer("maxPlayers"), "my_res")` reads the convar
   * `my_res:maxPlayers`.
   */
  readonly separator?: string
}

/**
 * An Effect `ConfigProvider` backed by FiveM convars (`GetConvar`).
 *
 * Convars are flat strings, so every lookup yields a leaf value or nothing:
 * an unset convar is "missing", which lets `Config.withDefault` and
 * `Config.option` behave as usual.
 *
 * ```ts
 * const maxPlayers = yield* Config.integer("my_max")   // `set my_max 32`
 * ```
 */
export const convarProvider = (options: ConvarProviderOptions = {}): ConfigProvider.ConfigProvider => {
  const separator = options.separator ?? ":"
  return ConfigProvider.make((path) =>
    Effect.sync(() => {
      if (path.length === 0) return undefined
      const value = GetConvar(path.join(separator), UNSET)
      return value === UNSET ? undefined : ConfigProvider.makeValue(value)
    })
  )
}

/** Replaces the active `ConfigProvider` with {@link convarProvider}. */
export const layer = (options?: ConvarProviderOptions): Layer.Layer<never> =>
  ConfigProvider.layer(convarProvider(options))

/**
 * Shorthands for reading one convar, named like FiveM's `GetConvarInt` family.
 * They are Effect 4's `Config.Int`, `Config.Number`, ... under friendlier names.
 *
 * ```ts
 * const max = yield* Config.integer("my_max")
 * ```
 */
export const integer = (name: string): Config.Config<number> => Config.Int(name)
export const number = (name: string): Config.Config<number> => Config.Number(name)
export const string = (name: string): Config.Config<string> => Config.String(name)
export const boolean = (name: string): Config.Config<boolean> => Config.Boolean(name)
