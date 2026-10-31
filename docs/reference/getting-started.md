# Getting started

This page takes a resource from nothing to a validated net event and a typed RPC, and lists every setting Rivo FX reads: convars, ACE permissions and editor types. Read [Introduction](introduction.md) first for what the library is.

## 1. Install the rivo_fx resource

Download `rivo_fx.zip` from the [latest release](https://github.com/RivoLabs/rivo_fx/releases/latest) and unzip it into your resources folder. The folder must be named `rivo_fx`. Start it before anything that uses it:

```cfg
ensure rivo_fx
ensure my_shop
```

## 2. Load it in your resource

```lua
-- my_shop/fxmanifest.lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
server_script 'server.lua'
client_script 'client.lua'
```

`@rivo_fx/init.lua` defines the global `Fx` in your resource's runtime. Core modules load at once; FiveM modules (`Fx.net`, `Fx.rpc`, `Fx.assets`, ...) load the first time you use them. Lua 5.4 (`lua54 'yes'`) is required.

Or start from a template with the CLI ([CLI](cli.md)):

```sh
npx @rivolabs/fx-cli create my_shop                      # server + client
npx @rivolabs/fx-cli create my_shop --template lua-nui   # plus a NUI page
```

## 3. A validated net event

```lua
-- server.lua
local S = Fx.S

Fx.net.handle('shop:buy', S.struct { item = S.string:maxChars(32), qty = S.int:between(1, 10) },
  function(src, input)
    return Fx.logInfo('purchase', { player = src, item = input.item, qty = input.qty })
  end)
```

```lua
-- client.lua
Fx.net.send('shop:buy', { item = 'water', qty = 2 })
```

The schema runs before the handler. A payload that fails it never reaches your code and is reported as a security event. Each player is limited to 10 calls per second per event unless you pass `{ rateLimit = '5/s' }` (or `false`). See [Net events and RPC](net-rpc.md).

## 4. A typed RPC

```lua
-- server.lua
local OutOfStock = Fx.TaggedError('OutOfStock')
local stock = { water = 3 }

Fx.rpc.register('shop:stock', { input = S.string:maxChars(32) }, function(src, item)
  if (stock[item] or 0) == 0 then return OutOfStock { item = item }:fail() end
  return stock[item]
end)
```

```lua
-- client.lua
Fx.runFork(Fx.rpc.call('shop:stock', 'water', { timeout = 5000 })
  :map(function(n) print('in stock', n) end)
  :catchTag('OutOfStock', function(e) print('sold out:', e.item) return Fx.unit end))
```

## 5. Editor types

Point LuaLS at the bundled type definitions, for example in `.luarc.json`:

```json
{ "workspace.library": ["../rivo_fx/types"] }
```

## Settings Rivo FX reads

| Setting | Kind | Default | What it does |
|---|---|---|---|
| `rivo_fx:logLevel` | convar | `info` | `debug`, `info`, `warn`, `error` or `none` for `Fx.log` and the `Fx.logInfo` family |
| `rivo_fx:tracing` | convar | `on` | `off` stops recording spans |
| `rivo_fx:metricsToken` | convar (server, use `set`, not `setr`) | unset | turns on `/rivo_fx/metrics` and `/rivo_fx/spans`; requests need `Authorization: Bearer <token>` |
| `rivo_fx.devtools` | ACE | none | who may open `/fxdev`, e.g. `add_ace group.admin rivo_fx.devtools allow` |

See [Metrics, tracing and logs](observability.md) and [Devtools](devtools.md).

## JavaScript and TypeScript resources

```sh
npm install @rivolabs/fx effect       # resources, on the real Effect package
npm install @rivolabs/fx-nui          # NUI pages
```

JS and Lua resources speak the same protocol: a Lua client can call a TypeScript RPC and the other way round, and typed errors cross both ways. See [JS/TS](js.md) and [NUI](nui.md).

## Next

- New to effects: [Effects](core-effects.md), then [Errors](core-errors.md).
- Moving an existing resource: [Moving a resource to Rivo FX](../MIGRATING.md).
- Copy-paste solutions: [Recipes](recipes.md).
