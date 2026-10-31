import { Effect, Schema, type Scope } from "effect"
import { poll } from "./poll.js"

/** The model is not in the game's CD image (or is not a valid model). */
export class InvalidModel extends Schema.TaggedError<InvalidModel>()("InvalidModel", {
  model: Schema.Union([Schema.String, Schema.Number])
}) {}

/** The animation dictionary does not exist. */
export class InvalidAnimDict extends Schema.TaggedError<InvalidAnimDict>()("InvalidAnimDict", {
  animDict: Schema.String
}) {}

/** An asset did not finish loading in time. */
export class AssetTimeout extends Schema.TaggedError<AssetTimeout>()("AssetTimeout", {
  kind: Schema.Literals(["model", "animDict", "ptfxAsset"]),
  asset: Schema.Union([Schema.String, Schema.Number]),
  timeoutMs: Schema.Number
}) {}

export interface LoadOptions {
  /** Milliseconds before failing with `AssetTimeout`. Defaults to 10 000. */
  readonly timeout?: number | undefined
  /** Milliseconds between `HasXLoaded` checks. Defaults to 0 (every tick). */
  readonly interval?: number | undefined
}

const DEFAULT_TIMEOUT_MS = 10_000

const load = (options: {
  readonly kind: AssetTimeout["kind"]
  readonly asset: string | number
  readonly loaded: () => boolean
  readonly request: () => void
  readonly release: () => void
  readonly load: LoadOptions
}): Effect.Effect<void, AssetTimeout> => {
  const timeoutMs = options.load.timeout ?? DEFAULT_TIMEOUT_MS
  return Effect.suspend(() => {
    if (options.loaded()) return Effect.void
    options.request()
    return poll(() => (options.loaded() ? true : undefined), {
      timeoutMs,
      intervalMs: options.load.interval ?? 0,
      onTimeout: () => new AssetTimeout({ kind: options.kind, asset: options.asset, timeoutMs })
    }).pipe(
      // A request that never completed is released rather than left pending.
      Effect.onError(() => Effect.sync(options.release)),
      Effect.asVoid
    )
  })
}

const toHash = (model: string | number): number => (typeof model === "string" ? GetHashKey(model) : model)

/**
 * Loads a model (`RequestModel` + `HasModelLoaded` polling) and returns its hash.
 * Fails with `InvalidModel` when the model does not exist, `AssetTimeout` when it does not load in time.
 */
export const model = (model: string | number, options: LoadOptions = {}): Effect.Effect<number, InvalidModel | AssetTimeout> =>
  Effect.suspend((): Effect.Effect<number, InvalidModel | AssetTimeout> => {
    const hash = toHash(model)
    if (!IsModelInCdimage(hash) || !IsModelValid(hash)) return Effect.fail(new InvalidModel({ model }))
    return load({
      kind: "model",
      asset: model,
      loaded: () => HasModelLoaded(hash),
      request: () => RequestModel(hash),
      release: () => SetModelAsNoLongerNeeded(hash),
      load: options
    }).pipe(Effect.as(hash))
  })

/** {@link model}, released with `SetModelAsNoLongerNeeded` when the scope closes. */
export const modelScoped = (
  name: string | number,
  options?: LoadOptions
): Effect.Effect<number, InvalidModel | AssetTimeout, Scope.Scope> =>
  Effect.acquireRelease(model(name, options), (hash) => Effect.sync(() => SetModelAsNoLongerNeeded(hash)))

/** Loads an animation dictionary. Fails with `InvalidAnimDict` or `AssetTimeout`. */
export const animDict = (dict: string, options: LoadOptions = {}): Effect.Effect<string, InvalidAnimDict | AssetTimeout> =>
  Effect.suspend((): Effect.Effect<string, InvalidAnimDict | AssetTimeout> => {
    if (!DoesAnimDictExist(dict)) return Effect.fail(new InvalidAnimDict({ animDict: dict }))
    return load({
      kind: "animDict",
      asset: dict,
      loaded: () => HasAnimDictLoaded(dict),
      request: () => RequestAnimDict(dict),
      release: () => RemoveAnimDict(dict),
      load: options
    }).pipe(Effect.as(dict))
  })

/** {@link animDict}, released with `RemoveAnimDict` when the scope closes. */
export const animDictScoped = (
  dict: string,
  options?: LoadOptions
): Effect.Effect<string, InvalidAnimDict | AssetTimeout, Scope.Scope> =>
  Effect.acquireRelease(animDict(dict, options), (d) => Effect.sync(() => RemoveAnimDict(d)))

/** Loads a named particle effect asset. Fails with `AssetTimeout`. */
export const ptfxAsset = (asset: string, options: LoadOptions = {}): Effect.Effect<string, AssetTimeout> =>
  load({
    kind: "ptfxAsset",
    asset,
    loaded: () => HasNamedPtfxAssetLoaded(asset),
    request: () => RequestNamedPtfxAsset(asset),
    release: () => RemoveNamedPtfxAsset(asset),
    load: options
  }).pipe(Effect.as(asset))

/** {@link ptfxAsset}, released with `RemoveNamedPtfxAsset` when the scope closes. */
export const ptfxAssetScoped = (asset: string, options?: LoadOptions): Effect.Effect<string, AssetTimeout, Scope.Scope> =>
  Effect.acquireRelease(ptfxAsset(asset, options), (a) => Effect.sync(() => RemoveNamedPtfxAsset(a)))
