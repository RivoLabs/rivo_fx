# NUI

This page covers typed NUI: the Lua side `Fx.nui` in a client script, and the page side `@rivolabs/fx-nui`, a dependency-free TypeScript package for the browser page (React, Svelte, Vue or plain JS). Together they replace raw `RegisterNUICallback` / `SendNUIMessage` / `fetch`: page calls are checked against a [Schema](core-schema.md), answers carry either a value or a tagged error, and the page can branch on the error's tag the way Lua code uses `catchTag`. It also covers running the page in a normal browser while you build it.

## Wire format

A callback registered with `Fx.nui.handle` always answers with one of:

```ts
{ ok: true, value: unknown }
{ ok: false, error: { _tag: string, ...fields } }
```

| `_tag` | When | Fields |
|---|---|---|
| `NuiInvalidInput` | the body failed `spec.input` | `name`, `message` (the schema's message) |
| your tag (`OutOfStock`, `InsufficientFunds`, ...) | the handler failed with a tagged error, including one from `Fx.rpc.call` | the error's fields, serialized with `Fx.serializeError` (functions dropped) |
| `NuiInternalError` | the handler raised, died, failed with something that is not a tagged error, or returned a value that failed `spec.output` | `name` only. The cause is logged in the client console with `Fx.log.error`, never sent to the page |
| `NuiInterrupted` | the handler's fiber was interrupted (for example on resource stop) | `name` |

The page side adds two tags of its own: `NuiTimeout` and `NuiTransportError` (see [fetchNui](#fetchnuiname-input-options)).

Messages from `Fx.nui.send` arrive in the page as a window `message` event whose `data` is `{ type, payload }`.

## Lua side: Fx.nui

All of `Fx.nui` is client-side. Error classes on `Fx.nui`: `NuiInvalidInput` and `NuiInvalidMessage`. `NuiInternalError` and `NuiInterrupted` exist only as tags in callback answers; there are no classes for them. See [Errors](errors.md).

### Fx.nui.handle(name, spec, handler)

```lua
Fx.nui.handle(name: string, spec: { input: Fx.Schema, output?: Fx.Schema }, handler: fun(input: any): any)
-- name: the callback name the page fetches
-- handler: returns a value or an effect
```

- **Side:** client.
- **Parameters:**
  - `name`: registered with `RegisterNUICallback(name, ...)`; the page calls `fetchNui(name, body)`.
  - `spec.input`: required. Checked against the request body; the handler gets the schema's output (unknown struct keys stripped).
  - `spec.output`: optional. Checked against the handler's result before it is sent.
  - `handler(input)`: returns a plain value or an effect.
- **Returns:** nothing. Not an effect; the callback is registered right away.
- **Fails with:** raises a Lua error at call time when `spec.input` is missing. At request time it never raises; every outcome becomes an answer (see [Wire format](#wire-format)).
- **Notes:**
  - Each request runs on its own fiber, so the handler can suspend (`Fx.rpc.call`, `Fx.sleep`) and `cb` is called when it ends. The page's fetch is never left hanging, even when the fiber is interrupted.
  - The handler's fiber has no `Scope` service. Wrap scoped work in `Fx.scoped`.
  - An `output` mismatch is treated as a bug in your code: the page gets `NuiInternalError` and the message `nui callback "<name>" returned invalid output: ...` is logged.

```lua
local S = Fx.S
local OutOfStock = Fx.TaggedError('OutOfStock')

Fx.nui.handle('buy', {
  input = S.struct { item = S.string, qty = S.int:between(1, 10) },
  output = S.struct { item = S.string, qty = S.int, paid = S.int, cash = S.int },
}, function(input)
  if input.item == 'gold' then return OutOfStock { item = input.item }:fail() end
  -- the server's tagged errors (InsufficientFunds, ...) reach the page as their tag
  return Fx.rpc.call('shop:buy', input, { timeout = 5000 })
end)
```

### Fx.nui.send(msgType, payload, schema)

```lua
Fx.nui.send(msgType: string, payload?: any, schema?: Fx.Schema) -> Fx.Effect<nil, NuiInvalidMessage>
```

- **Side:** client.
- **Parameters:** `msgType`, the `type` the page listens for with `onMessage`; `payload`; `schema`, checked against `payload` first.
- **Returns:** `nil` after `SendNUIMessage({ type = msgType, payload = payload })`. With a schema, the schema's output is sent.
- **Fails with:** `NuiInvalidMessage { type, message }` when `payload` fails `schema`; nothing is sent.
- **Notes:** it is an effect, so it sends nothing until run (`Fx.yield`, `Fx.runFork`).

```lua
local Open = S.struct { title = S.string, items = S.array(S.string) }
Fx.yield(Fx.nui.send('open', { title = '24/7 Supermarket', items = { 'water', 'bread', 'phone' } }, Open))
```

### Fx.nui.useFocus(opts)

```lua
Fx.nui.useFocus(opts?: { cursor?: boolean, keepInput?: boolean }) -> Fx.Effect<nil, never>
-- requires Scope
```

- **Side:** client.
- **Parameters:** `opts.cursor`, show the cursor (default `true`); `opts.keepInput`, also call `SetNuiFocusKeepInput(true)` so the game keeps receiving input.
- **Returns:** `nil`. Calls `SetNuiFocus(true, cursor)` when it runs.
- **Fails with:** never.
- **Notes:** when the scope closes, it calls `SetNuiFocus(false, false)` (and `SetNuiFocusKeepInput(false)` if `keepInput` was set). Focus is released however the scope ends: success, failure, interruption or resource stop.

```lua
-- /shop opens the page; the 'close' callback interrupts the fiber, which releases focus
local open

RegisterCommand('shop', function()
  if open then return end
  open = Fx.runFork(Fx.scoped(Fx.gen(function()
    Fx.yield(Fx.nui.useFocus())
    Fx.yield(Fx.nui.send('open', { items = { 'water', 'bread', 'phone' } }))
    Fx.yield(Fx.never)
  end)):ensuring(Fx.sync(function()
    open = nil
    SendNUIMessage({ type = 'close' })
  end)))
end, false)

Fx.nui.handle('close', { input = S.struct {} }, function()
  if open then open:interruptAsFork(0) end
  return true
end)
```

## Page side: @rivolabs/fx-nui

```sh
npm install @rivolabs/fx-nui
```

The package ships ESM and CJS builds with type declarations. Its exports: `fetchNui`, `FetchNuiOptions` (type), `NuiError`, `isNuiError`, `onMessage`, `emitMessage`, `mockNui`, `isInGame`, `resourceName`, `setDevResource`. To generate the payload types from the same JSON schema as your Lua validators, see [CLI](cli.md).

### fetchNui(name, input, options)

```ts
interface FetchNuiOptions {
  /** Milliseconds before rejecting with NuiTimeout. Default 10000; 0 waits forever. */
  readonly timeout?: number
  /** Call another resource's callback (default: this page's resource). */
  readonly resource?: string
  readonly signal?: AbortSignal
}

function fetchNui<O = unknown, I = unknown>(name: string, input?: I, options?: FetchNuiOptions): Promise<O>
```

- **Side:** page.
- **Parameters:** `name`, the `Fx.nui.handle` name; `input`, the body (sent as `JSON.stringify(input ?? {})`); `options`.
- **Returns:** a promise of the handler's `value`.
- Fails with (rejects with a `NuiError`):
  - the handler's own tag, `NuiInvalidInput`, `NuiInternalError` or `NuiInterrupted`, as answered by Lua;
  - `NuiInternalError { name }` when the answer is `{ ok: false }` without a tagged `error`;
  - `NuiTimeout { name, timeoutMs }` when `timeout` runs out;
  - `NuiTransportError { name, status }` for a non-2xx HTTP response;
  - `NuiTransportError { name, message }` when `fetch` itself fails, including when `options.signal` aborts the request.
- **Notes:**
  - Posts to `https://<resource>/<name>` with `Content-Type: application/json; charset=UTF-8`, where `<resource>` is `options.resource ?? resourceName()`.
  - Answers that are not `{ ok: boolean, ... }` are returned as they are, so it also works with plain `RegisterNUICallback` handlers. An empty body resolves to `undefined`; a body that is not JSON resolves to the text.
  - Outside the game, a mock registered with `mockNui(name, ...)` answers instead and `fetch` is not called. Mocks skip the timeout, the signal and the `{ ok }` unwrapping, and an error thrown by a mock rejects unchanged (it is not wrapped in a `NuiError`).
  - A signal that is already aborted when you call `fetchNui` is not noticed; only an abort during the request cancels it.
  - The type parameters are not checked at runtime. Validate on the Lua side with `spec.output` if the page relies on the shape.

```ts
import { fetchNui, isNuiError } from "@rivolabs/fx-nui"

type Receipt = { item: string; qty: number; paid: number; cash: number }

try {
  const r = await fetchNui<Receipt>("buy", { item: "water", qty: 2 }, { timeout: 5000 })
  setStatus(`Bought ${r.qty}x ${r.item} for $${r.paid}`)
} catch (e) {
  if (isNuiError(e, "InsufficientFunds")) setStatus(`Need $${e.fields.need}, have $${e.fields.have}`)
  else if (isNuiError(e, "NuiInvalidInput")) setStatus(`Check the order: ${e.fields.message}`)
  else throw e
}
```

### NuiError

```ts
class NuiError extends Error {
  readonly _tag: string
  readonly fields: Readonly<Record<string, unknown>>
  constructor(tag: string, fields?: Record<string, unknown>)
}
```

- **Side:** page.
- **Notes:**
  - `name` is `"NuiError"`.
  - `_tag` is the error's tag.
  - `fields` holds every field sent with the error, plus `_tag`.
  - `message` is `"<tag>: <fields.message>"` when `fields.message` is a string, otherwise just `"<tag>"`.
  - Throw one from a `mockNui` handler to simulate a Lua failure.

```ts
import { NuiError } from "@rivolabs/fx-nui"

const e = new NuiError("OutOfStock", { item: "gold" })
e._tag            // "OutOfStock"
e.fields          // { item: "gold", _tag: "OutOfStock" }
e.message         // "OutOfStock"
```

### isNuiError(err, tag)

```ts
function isNuiError(err: unknown, tag?: string): err is NuiError
```

- **Side:** page.
- **Returns:** `true` when `err` is a `NuiError` and, if `tag` is given, its `_tag` equals `tag`. Narrows the type.
- **Fails with:** never.

```ts
catch (e) {
  if (isNuiError(e, "OutOfStock")) showSoldOut(e.fields.item as string)
}
```

### onMessage(type, handler)

```ts
function onMessage<P = unknown>(type: string, handler: (payload: P) => void): () => void
```

- **Side:** page.
- **Parameters:** `type`, matched against `event.data.type`; `handler`, called with `event.data.payload`.
- **Returns:** a function that removes the listener.
- **Fails with:** never. Errors thrown by `handler` are not caught.
- **Notes:** listens to `window` `message` events, so it receives every `Fx.nui.send(type, payload)` from the resource and every `emitMessage(type, payload)`. Messages of other types and non-object `data` are ignored. The payload type is not checked at runtime.

```ts
import { onMessage } from "@rivolabs/fx-nui"

const stop = onMessage<{ items: string[] }>("open", ({ items }) => render(items))
// later, e.g. in a React effect cleanup
stop()
```

### emitMessage(type, payload)

```ts
function emitMessage<P = unknown>(type: string, payload?: P): void
```

- **Side:** page.
- **Returns:** nothing. Dispatches a `MessageEvent("message", { data: { type, payload } })` on `window`, the same shape `Fx.nui.send` produces.
- **Notes:** for running the page outside the game and for tests.

```ts
import { emitMessage, isInGame } from "@rivolabs/fx-nui"

if (!isInGame()) emitMessage("open", { items: ["water", "bread", "phone"] })
```

### mockNui(name, handler)

```ts
function mockNui<I = unknown, O = unknown>(name: string, handler: (input: I) => O | Promise<O>): () => void
```

- **Side:** page.
- **Parameters:** `name`, the callback to answer; `handler`, gets the `input` passed to `fetchNui`.
- **Returns:** a function that removes the mock (only if it is still the registered one for `name`).
- **Notes:**
  - Used only when `isInGame()` is false; in game, mocks are ignored.
  - Return a value (or a promise) to resolve the call. Throw a `NuiError` to reject it the way Lua would.
  - One mock per name; registering again replaces it.

```ts
import { mockNui, NuiError } from "@rivolabs/fx-nui"

mockNui<{ item: string; qty: number }, { item: string; qty: number; paid: number; cash: number }>("buy", ({ item, qty }) => {
  if (qty * 5 > 100) throw new NuiError("InsufficientFunds", { need: qty * 5, have: 100 })
  return { item, qty, paid: qty * 5, cash: 100 - qty * 5 }
})
```

### isInGame()

```ts
function isInGame(): boolean
```

- **Side:** page.
- **Returns:** `true` when `globalThis.GetParentResourceName` is a function, which FiveM's CEF injects into NUI pages.

```ts
if (!isInGame()) document.body.style.background = "#333"   // no game behind the page in a browser
```

### resourceName()

```ts
function resourceName(): string
```

- **Side:** page.
- **Returns:** `GetParentResourceName()` in game; outside the game, the name set with `setDevResource` (default `"nui-dev"`).

```ts
console.log(`page for ${resourceName()}`)
```

### setDevResource(name)

```ts
function setDevResource(name: string): void
```

- **Side:** page.
- **Notes:** sets the name `resourceName()` returns outside the game, and so the host `fetchNui` posts to (`https://<name>/<callback>`) when no mock answers. Has no effect in game.

```ts
setDevResource("my_shop")
```

## Developing the page in a normal browser

Outside FiveM there is no `GetParentResourceName`, so `isInGame()` is false. Then:

1. Register a `mockNui` for every callback the page calls. Without a mock, `fetchNui` posts to `https://nui-dev/<name>` (or the `setDevResource` name), which normally fails with `NuiTransportError`.
2. Use `emitMessage` to play the messages the Lua side would send with `Fx.nui.send`.
3. Keep the mocks in the shipped page if you like: they are ignored in game.

```ts
// main.ts
import { emitMessage, isInGame, mockNui, NuiError } from "@rivolabs/fx-nui"

if (!isInGame()) {
  let cash = 100
  mockNui<{ item: string; qty: number }>("buy", ({ item, qty }) => {
    const paid = qty * 5
    if (paid > cash) throw new NuiError("InsufficientFunds", { need: paid, have: cash })
    cash -= paid
    return { item, qty, paid, cash }
  })
  mockNui("close", () => true)
  emitMessage("open", { items: ["water", "bread", "phone"] })
}
```

Then run any dev server (or open `index.html` directly, as the `lua-nui` template does) and work on the page with the browser's devtools. `npx rivo-fx create my_shop --template lua-nui` scaffolds a resource with a page wired this way ([CLI](cli.md)).
