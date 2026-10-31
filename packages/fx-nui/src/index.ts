/**
 * The page half of Rivo FX NUI. Pairs with `Fx.nui.handle` / `Fx.nui.send`
 * in the resource's client script.
 *
 *   const result = await fetchNui<{ bought: string }>("buy", { item: "apple", qty: 2 })
 *   onMessage<{ items: string[] }>("open", (payload) => render(payload.items))
 *
 * A callback answers `{ ok: true, value }` or `{ ok: false, error: { _tag, ... } }`.
 * `fetchNui` resolves with the value and rejects with a `NuiError` whose `_tag`
 * is the error's tag, so a page can branch on it the way Lua code does with
 * `catchTag`.
 */

/** A failure reported by the resource, or by the transport. */
export class NuiError extends Error {
  /** The error's tag: `NuiInvalidInput`, `NuiInternalError`, `NuiTimeout`, or the handler's own tag. */
  readonly _tag: string
  /** Every field the resource sent with the error (including `_tag`). */
  readonly fields: Readonly<Record<string, unknown>>

  constructor(tag: string, fields: Record<string, unknown> = {}) {
    const detail = typeof fields["message"] === "string" ? `: ${fields["message"]}` : ""
    super(`${tag}${detail}`)
    this.name = "NuiError"
    this._tag = tag
    this.fields = { ...fields, _tag: tag }
  }
}

/** True when `err` is a NuiError, optionally with the given tag. */
export const isNuiError = (err: unknown, tag?: string): err is NuiError =>
  err instanceof NuiError && (tag === undefined || err._tag === tag)

type Mock = (input: unknown) => unknown

const mocks = new Map<string, Mock>()
let devResource = "nui-dev"

const parentResourceName = (): string | undefined => {
  const fn = (globalThis as { GetParentResourceName?: () => string }).GetParentResourceName
  return typeof fn === "function" ? fn() : undefined
}

/** True inside the game (CEF injects `GetParentResourceName`). */
export const isInGame = (): boolean => parentResourceName() !== undefined

/** The resource this page belongs to. Outside the game: the name set with `setDevResource`. */
export const resourceName = (): string => parentResourceName() ?? devResource

/** Name to use for `resourceName()` when the page runs outside the game (a dev server). */
export const setDevResource = (name: string): void => {
  devResource = name
}

/**
 * Answer `fetchNui(name)` outside the game, for working on the page in a normal
 * browser. Return a value to resolve the call, or throw a `NuiError` to reject it.
 * In game, mocks are ignored. Returns a function that removes the mock.
 */
export const mockNui = <I = unknown, O = unknown>(name: string, handler: (input: I) => O | Promise<O>): (() => void) => {
  mocks.set(name, handler as Mock)
  return () => {
    if (mocks.get(name) === (handler as Mock)) mocks.delete(name)
  }
}

export interface FetchNuiOptions {
  /** Milliseconds before rejecting with `NuiTimeout`. Default 10000; 0 waits forever. */
  readonly timeout?: number
  /** Call another resource's callback (default: this page's resource). */
  readonly resource?: string
  readonly signal?: AbortSignal
}

const isEnvelope = (v: unknown): v is { ok: boolean; value?: unknown; error?: unknown } =>
  typeof v === "object" && v !== null && typeof (v as { ok?: unknown }).ok === "boolean"

const unwrap = <O>(name: string, body: unknown): O => {
  if (!isEnvelope(body)) return body as O // a plain RegisterNUICallback answer
  if (body.ok) return body.value as O
  const err = body.error
  if (typeof err === "object" && err !== null && typeof (err as { _tag?: unknown })._tag === "string") {
    throw new NuiError((err as { _tag: string })._tag, err as Record<string, unknown>)
  }
  throw new NuiError("NuiInternalError", { name })
}

/**
 * POST `input` to the resource's `name` callback and resolve with its value.
 * Rejects with a `NuiError`: the handler's tagged error, `NuiInvalidInput`,
 * `NuiInternalError`, `NuiTimeout`, or `NuiTransportError`.
 */
export const fetchNui = async <O = unknown, I = unknown>(
  name: string,
  input?: I,
  options: FetchNuiOptions = {}
): Promise<O> => {
  const mock = mocks.get(name)
  if (mock && !isInGame()) return (await mock(input)) as O

  const timeoutMs = options.timeout ?? 10000
  const controller = new AbortController()
  const onAbort = () => controller.abort()
  options.signal?.addEventListener("abort", onAbort)
  let timedOut = false
  const timer =
    timeoutMs > 0
      ? setTimeout(() => {
          timedOut = true
          controller.abort()
        }, timeoutMs)
      : undefined

  try {
    const res = await fetch(`https://${options.resource ?? resourceName()}/${name}`, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=UTF-8" },
      body: JSON.stringify(input ?? {}),
      signal: controller.signal
    })
    if (!res.ok) throw new NuiError("NuiTransportError", { name, status: res.status })
    const text = await res.text()
    let body: unknown
    try {
      body = text === "" ? undefined : JSON.parse(text)
    } catch {
      body = text
    }
    return unwrap<O>(name, body)
  } catch (err) {
    if (err instanceof NuiError) throw err
    if (timedOut) throw new NuiError("NuiTimeout", { name, timeoutMs })
    throw new NuiError("NuiTransportError", { name, message: err instanceof Error ? err.message : String(err) })
  } finally {
    if (timer !== undefined) clearTimeout(timer)
    options.signal?.removeEventListener("abort", onAbort)
  }
}

/**
 * Call `handler(payload)` for every `Fx.nui.send(type, payload)` from the
 * resource. Returns a function that stops listening.
 */
export const onMessage = <P = unknown>(type: string, handler: (payload: P) => void): (() => void) => {
  const listener = (event: Event) => {
    const data = (event as MessageEvent).data as { type?: unknown; payload?: unknown } | null
    if (data && typeof data === "object" && data.type === type) handler(data.payload as P)
  }
  window.addEventListener("message", listener)
  return () => window.removeEventListener("message", listener)
}

/** Deliver a message as if the resource sent it (outside the game, and in tests). */
export const emitMessage = <P = unknown>(type: string, payload?: P): void => {
  window.dispatchEvent(new MessageEvent("message", { data: { type, payload } }))
}
