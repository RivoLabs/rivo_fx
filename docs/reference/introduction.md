# Introduction

Rivo FX is a free, MIT-licensed library for FiveM resources, in Lua 5.4 and in JavaScript/TypeScript. It brings the model of [Effect](https://effect.website) to FiveM: errors are values you can see in the type, fibers clean up after themselves, services come from Layers, and every payload that crosses a trust boundary goes through a schema. On top of that it covers the FiveM parts scripts most often get wrong: net events, callbacks, asset loading, entities, state bags, NUI, the database and frameworks.

## What it fixes

- **Net events that validate first.** A handler never sees a payload that fails its schema, and every player is rate limited per event by default. Rejected payloads become security events you can log or send to a webhook.
- **RPC with timeouts and typed errors.** A `NotEnoughMoney` raised on the server arrives on the client as `NotEnoughMoney`, so `catchTag` works across the wire. Calls time out and cancel the handler. Defects never leak details to clients.
- **Cleanup that actually runs.** Scopes close when the resource stops or the player drops: spawned entities are deleted, models released and in-flight handlers interrupted.
- **No more `while not HasModelLoaded(m) do Wait(0) end`.** Asset loads have timeouts and typed errors.
- **One API over ESX, QBCore, Qbox and standalone**, typed oxmysql queries, schema-typed state bags and KVP.
- **Metrics, tracing and in-game devtools.** `/fxdev` shows live fibers, traces (a client call and its server handler share one trace), failures and metrics for every resource.

## Install

1. Download `rivo_fx.zip` from the [latest release](https://github.com/RivoLabs/rivo_fx/releases/latest), unzip it into your resources folder (the folder must be named `rivo_fx`) and `ensure rivo_fx` before anything that uses it.
2. In your resource's `fxmanifest.lua`:

```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
```

The library loads into your resource's own Lua runtime, the way `ox_lib` does. No exports sit on the hot path, and FiveM modules load on first use. The global `Fx` holds everything. See [Getting started](getting-started.md) for types, convars and the JS packages.

## A taste

```lua
local S = Fx.S
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')

-- a service, provided by a Layer
local Bank = Fx.Tag('Bank')
local BankLive = Fx.Layer.succeed(Bank, {
  withdraw = function(src, amount)
    return Fx.suspend(function()
      local have = balances[src] or 0
      if have < amount then return NotEnoughMoney { have = have, need = amount }:fail() end
      balances[src] = have - amount
      return Fx.succeed(balances[src])
    end)
  end,
})
Fx.setRuntime(Fx.Runtime.make(BankLive))

-- server: validated, rate limited, typed
Fx.rpc.register('bank:withdraw', { input = S.struct { amount = S.int:between(1, 1e6) } },
  function(src, input)
    return Fx.gen(function()
      local bank = Fx.yield(Bank)
      return Fx.yield(bank.withdraw(src, input.amount))
    end)
  end)
```

```lua
-- client
Fx.runFork(Fx.gen(function()
  local balance = Fx.yield(
    Fx.rpc.call('bank:withdraw', { amount = 500 }, { timeout = 5000 })
      :catchTag('NotEnoughMoney', function(e)
        return Fx.succeed(e.have)
      end)
  )
  print('balance now', balance)
end))
```

## Level 0: use it without learning Effect

Already have a codebase? Start with `Fx.runAwait`. It runs an effect from any Citizen thread and returns the value, or raises the error so `pcall` works:

```lua
CreateThread(function()
  local hash = Fx.runAwait(Fx.assets.model('adder', { timeout = 5000 }))
  -- ... spawn something
end)
```

## How these docs are organised

- **Core:** [Effects](core-effects.md), [Errors](core-errors.md), [Concurrency](core-concurrency.md), [Scopes, services and Layers](core-resources.md), [Schedule](core-schedule.md), [Schema](core-schema.md).
- **Values over time and visibility:** [Streams](streams.md), [Metrics, tracing and logs](observability.md), [Devtools](devtools.md).
- **FiveM:** [Net events and RPC](net-rpc.md), [Players, config, assets, entities, ticks](fivem-modules.md), [KVP, state bags, database, frameworks](data.md), [NUI](nui.md).
- **JavaScript and tools:** [JS/TS (@rivolabs/fx)](js.md), [CLI (rivo-fx)](cli.md).
- **Practical:** [Recipes](recipes.md), [Errors and gotchas](errors.md), [Moving a resource to Rivo FX](../MIGRATING.md).

Every reference page uses the same layout: one heading per function with its signature, parameters, return value, the errors it can fail with, notes and an example. The whole reference is also one file, [llms-full.md](https://github.com/RivoLabs/rivo_fx/blob/main/llms-full.md), for AI assistants.

## What's next

- OpenTelemetry (OTLP) export of spans and metrics
- A layer graph view in `/fxdev`
- An ox_core framework layer
- A TypeScript resource template for `rivo-fx create`

Source, issues and releases are on [GitHub](https://github.com/RivoLabs/rivo_fx). Security issues go through [private reporting](https://github.com/RivoLabs/rivo_fx/security/advisories/new).
