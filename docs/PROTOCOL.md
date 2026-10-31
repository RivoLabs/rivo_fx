# Rivo FX wire protocol (v1)

Lua and JS resources built on Rivo FX talk to each other over this protocol, so
a Lua client can call a JS server RPC and the other way round. Both
implementations must follow it exactly.

## Net events

`Fx.net.handle(name, schema, handler)` / `Net.handle(name, schema, handler)`
registers a plain FiveM net event called `name`.

- The event carries **exactly one argument**: the payload.
- Senders use `TriggerServerEvent(name, payload)` or
  `TriggerClientEvent(name, target, payload)`.
- The receiver decodes the payload with the schema before the handler runs.
  When decoding fails, the handler does not run and a `SecurityEvent` of kind
  `invalid_payload` is published.

## RPC

Every resource that registers or calls RPCs listens on three events, where
`<res>` is `GetCurrentResourceName()`:

| Event | Direction | Payload |
|---|---|---|
| `__rfx:<res>:req` | caller → host | `{ id, name, from, input, trace? }` |
| `__rfx:<res>:res` | host → caller | `{ id, ok, value }` or `{ id, ok, error }` |
| `__rfx:<res>:cancel` | caller → host | `{ id, from }` |

- `id` is an integer that is unique per caller resource (and per client when
  the caller is a client).
- `name` is the RPC name.
- `from` is the caller's resource name. The host sends the response to
  `__rfx:<from>:res`.
- `trace` (optional) is the W3C `traceparent` of the caller's span
  (`00-<32 hex trace id>-<16 hex span id>-01`, at most 64 characters). The
  host runs the handler in a span that continues that trace. A missing or
  malformed `trace` starts a new trace; it never rejects the request. Hosts
  that do not trace ignore the field.
- Requests go to `__rfx:<target>:req`. `<target>` is the caller's own resource
  unless the call sets `resource`.
- Client → server: `TriggerServerEvent`. The host reads the player from
  `source`.
- Server → client: `TriggerClientEvent(event, playerId, payload)`. The client
  host replies with `TriggerServerEvent`, and the server matches the response
  on `(source, id)`.

### Response

Success: `{ id = 1, ok = true, value = <output> }`.

Failure: `{ id = 1, ok = false, error = { _tag = "SomeTag", ...fields } }`.

Only **tagged errors** (expected failures, `E` in `Effect<A, E, R>`) cross the
wire, with their own `_tag` and serialisable fields. Defects and interruptions
never leak details. They become `RpcInternalError`.

Errors the protocol itself produces:

| `_tag` | When | Fields |
|---|---|---|
| `RpcNotFound` | no handler with that name on the host | `name` |
| `RpcInvalidInput` | input failed the host's schema | `name`, `message` |
| `RpcRateLimited` | the caller exceeded the handler's rate limit | `name` |
| `RpcInternalError` | the handler died or was interrupted | `name` |
| `RpcTimeout` | raised **locally** by the caller when no response arrives in time | `name`, `timeoutMs` |
| `RpcInvalidOutput` | raised **locally** by the caller when the response fails its output schema | `name`, `message` |

On the caller's side, a failed response is rebuilt as a tagged error with the
same `_tag` and fields, so `catchTag("NotEnoughMoney", ...)` works on the
caller exactly as it would on the host.

### Host processing order

A host handles each request in this order and stops at the first problem:

1. A malformed envelope (not `{ id, name, from, input }`) is dropped with no
   reply. On the server it publishes `invalid_payload` named `__rfx:<res>:req`.
2. An unknown `name` replies `RpcNotFound` and publishes `unknown_rpc`. Unknown
   names are not rate limited.
3. The handler's rate limit replies `RpcRateLimited` and publishes
   `rate_limited`. Net events and RPCs have separate buckets even when they
   share a name.
4. Input that fails the schema replies `RpcInvalidInput` and publishes
   `invalid_payload`.

Net events, requests, cancels and responses that reach the server without a player
`source` (another server script calling `TriggerEvent`) are ignored.

### Cancellation

When the calling fiber is interrupted (including by a timeout), the caller
sends `__rfx:<target>:cancel` with `{ id, from }`. The host interrupts the
handler fiber for that `(caller, id)` if it is still running, and sends no
response.

## Rate limits

Rate limits are written `"<n>/s"`, `"<n>/m"` or `"<n>/h"`. They are token
buckets: capacity `n`, refilled continuously at `n` per period, with one
bucket per (player, event or RPC name). The default is `"10/s"`. Pass
`rateLimit = false` to disable.

## SecurityEvents

These are published locally (inside the resource) when the server rejects
something a client sent:

```
{ kind = "invalid_payload" | "rate_limited" | "unknown_rpc",
  source = <player id>, name = <event or rpc name>, message = <string?> }
```

Rivo FX also fires `TriggerEvent("rivo_fx:security", event, resourceName)` so
anticheat resources can listen to every resource in one place.
