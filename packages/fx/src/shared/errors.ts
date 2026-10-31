import { Data, Exit, Schema } from "effect"

/** No handler with that name on the host. */
export class RpcNotFound extends Schema.TaggedError<RpcNotFound>()("RpcNotFound", {
  name: Schema.String
}) {}

/** The input failed the host's schema. */
export class RpcInvalidInput extends Schema.TaggedError<RpcInvalidInput>()("RpcInvalidInput", {
  name: Schema.String,
  message: Schema.String
}) {}

/** The caller exceeded the handler's rate limit. */
export class RpcRateLimited extends Schema.TaggedError<RpcRateLimited>()("RpcRateLimited", {
  name: Schema.String
}) {}

/** The handler died or was interrupted. Defects never leak details across the wire. */
export class RpcInternalError extends Schema.TaggedError<RpcInternalError>()("RpcInternalError", {
  name: Schema.String
}) {}

/** Raised locally by the caller when no response arrives in time. */
export class RpcTimeout extends Schema.TaggedError<RpcTimeout>()("RpcTimeout", {
  name: Schema.String,
  timeoutMs: Schema.Number
}) {}

/** Raised locally by the caller when the response fails its output schema. */
export class RpcInvalidOutput extends Schema.TaggedError<RpcInvalidOutput>()("RpcInvalidOutput", {
  name: Schema.String,
  message: Schema.String
}) {}

/** Every error the RPC protocol itself can produce on the caller's side. */
export type RpcError =
  | RpcNotFound
  | RpcInvalidInput
  | RpcRateLimited
  | RpcInternalError
  | RpcTimeout
  | RpcInvalidOutput

/**
 * A tagged error the host failed with, rebuilt on the caller with the same
 * `_tag` and fields, so `Effect.catchTag("NotEnoughMoney", ...)` works on the
 * caller exactly as it would on the host.
 *
 * Pass `errors` to `Rpc.call` to decode known tags into your own classes instead.
 */
export class RemoteError extends Data.Error<{ readonly _tag: string; readonly [field: string]: unknown }> {}

/** The `error` field of a failed RPC response. */
export interface WireError {
  readonly _tag: string
  readonly [field: string]: unknown
}

const isRecord = (u: unknown): u is Record<string, unknown> => typeof u === "object" && u !== null

/** True for values with a string `_tag`: the only errors allowed to cross the wire. */
export const isTagged = (u: unknown): u is { readonly _tag: string } =>
  isRecord(u) && typeof u["_tag"] === "string"

/**
 * Turns an expected failure into its wire form: `_tag` plus its own
 * serialisable fields. Anything without a `_tag` becomes `RpcInternalError`.
 */
export const encodeError = (name: string, error: unknown): WireError => {
  if (!isTagged(error)) return { _tag: "RpcInternalError", name }
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(error)) {
    if (key === "stack" || typeof value === "function" || typeof value === "symbol") continue
    out[key] = value
  }
  // Effect errors keep `message` as an own, non-enumerable property.
  const message = Object.getOwnPropertyDescriptor(error, "message")?.value
  if (typeof message === "string" && message.length > 0) out["message"] = message
  out["_tag"] = error._tag
  return out as WireError
}

const protocolErrors = {
  RpcNotFound,
  RpcInvalidInput,
  RpcRateLimited,
  RpcInternalError,
  RpcTimeout,
  RpcInvalidOutput
} as const

/**
 * Rebuilds the `error` of a failed response as a tagged error.
 *
 * Protocol tags become their real classes. Other tags are decoded with
 * `errors` when given, and become a {@link RemoteError} otherwise.
 */
export const decodeError = (
  name: string,
  wire: unknown,
  errors?: Schema.Decoder<unknown>
): unknown => {
  if (!isTagged(wire)) return new RpcInternalError({ name })
  if (Object.hasOwn(protocolErrors, wire._tag)) {
    const schema = protocolErrors[wire._tag as keyof typeof protocolErrors] as unknown as Schema.Decoder<unknown>
    const exit = Schema.decodeUnknownExit(schema)(wire)
    return Exit.isSuccess(exit) ? exit.value : new RpcInternalError({ name })
  }
  if (errors !== undefined) {
    const exit = Schema.decodeUnknownExit(errors)(wire)
    if (Exit.isSuccess(exit)) return exit.value
  }
  return new RemoteError(wire)
}
