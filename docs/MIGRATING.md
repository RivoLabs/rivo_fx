# Moving a resource to Rivo FX

You do not have to rewrite anything up front. Rivo FX runs next to plain
Citizen code, `Fx.runAwait` works from any thread, and the ox_lib bridge keeps
old callers working while you move handlers over. Pick the pattern that hurts
most and start there.

Every "after" below assumes the resource loads Rivo FX:

```lua
dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
```

## Net events you validate by hand

Before: every handler re-checks its arguments (or forgets to), and nothing stops
a client from firing it 500 times a second.

```lua
RegisterNetEvent('shop:buy', function(item, qty)
  local src = source
  if type(item) ~= 'string' or type(qty) ~= 'number' or qty < 1 or qty > 10 then return end
  -- ...
end)
```

After: the schema runs first, the handler only sees clean input, each player is
rate limited, and rejected payloads are reported to `Fx.security.on`.

```lua
local S = Fx.S
Fx.net.handle('shop:buy', S.struct { item = S.string:maxChars(32), qty = S.int:between(1, 10) },
  function(src, input)
    -- input.item and input.qty are checked; unknown fields are dropped
  end, { rateLimit = '5/s' })
```

Clients send a table: `TriggerServerEvent('shop:buy', { item = 'water', qty = 2 })`
or `Fx.net.send('shop:buy', { ... })`.

## ox_lib callbacks

Before:

```lua
-- server
lib.callback.register('bank:balance', function(src, account) return getBalance(src, account) end)
-- client
local balance = lib.callback.await('bank:balance', false, 'main')
```

After: register the handler with Rivo FX and keep `libCallback = true` until
every caller is moved. Old `lib.callback.await` callers keep working (still
validated and rate limited), new callers get typed errors and timeouts.

```lua
-- server
Fx.rpc.register('bank:balance', { input = S.string, libCallback = true }, function(src, account)
  return Bank.balance(src, account) -- a value or an effect
end)
-- client, new style
local balance = Fx.yield(Fx.rpc.call('bank:balance', 'main', { timeout = 5000 }))
```

Calling a callback that still lives in ox_lib, from Rivo FX:
`Fx.compat.libCallback('other:thing', arg1, arg2, Fx.compat.opts { timeout = 3000 })`.

## ESX and QBCore callbacks

`ESX.RegisterServerCallback` and `QBCore.Functions.CreateCallback` hand you a
`cb` that the client waits on forever if the server errors. Replace them with
`Fx.rpc.register`; a failure reaches the caller as its tag, and the caller's
timeout always fires.

```lua
-- before
QBCore.Functions.CreateCallback('garage:spawn', function(src, cb, plate)
  local veh = spawn(plate)
  cb(veh ~= nil)
end)

-- after
local NotYours = Fx.TaggedError('NotYours')
Fx.rpc.register('garage:spawn', { input = S.string:maxChars(8) }, function(src, plate)
  if not owns(src, plate) then return NotYours { plate = plate }:fail() end
  return spawn(plate)
end)

-- client
Fx.rpc.call('garage:spawn', plate, { timeout = 5000 })
  :catchTag('NotYours', function() return Fx.succeed(nil) end)
```

## Money and jobs through the framework

Before: one code path per framework, and a failed removal is a `false` you have
to remember to check.

```lua
local Player = QBCore.Functions.GetPlayer(src)
if not Player.Functions.RemoveMoney('bank', 500, 'garage') then return end
```

After: one service for ESX, QBCore, Qbox and standalone. `removeMoney` fails
with `InsufficientFunds { need, have }` and never goes negative.

```lua
Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

local fw = Fx.yield(Fx.framework.Framework)
Fx.yield(fw.removeMoney(src, 'bank', 500, 'garage'))
fw.onPlayerLoaded(function(src) ... end)   -- fires once per character, on every framework
```

## oxmysql

Before: `MySQL.query.await` returns rows of whatever shape the table has today,
and a failed query is a printed error and a `nil`.

```lua
local rows = MySQL.query.await('SELECT id, money FROM players WHERE id = ?', { id })
```

After: rows are checked against a schema, and every failure is an `SqlError`
you can catch, retry or map.

```lua
local Row = S.struct { id = S.int, money = S.int }
local rows = Fx.yield(Fx.db.query('SELECT id, money FROM players WHERE id = ?', { id }, { row = Row })
  :retry(Fx.Schedule.exponential(100):take(3)))
```

## Loading models and dictionaries

```lua
-- before
RequestModel(model)
while not HasModelLoaded(model) do Wait(0) end   -- forever, if the model is wrong

-- after
local hash = Fx.yield(Fx.assets.model('adder', { timeout = 5000 }))   -- AssetNotFound / AssetTimeout
-- or released automatically when the scope closes:
Fx.yield(Fx.assets.useModel('adder'))
```

## Threads and loops

```lua
-- before: runs forever, even after you no longer need it
CreateThread(function()
  while true do
    Wait(0)
    if #(GetEntityCoords(PlayerPedId()) - shop) < 10.0 then DrawMarker(...) end
  end
end)

-- after: checks distance every 500 ms while away, runs every frame only when
-- close, and stops when the fiber is interrupted or its scope closes
local marker = Fx.runFork(Fx.tick.whileNear(shop, 10.0, function() DrawMarker(...) end))
marker:interruptAsFork(0) -- when you are done
```

Repeating work: `Fx.yield(Fx.sleep(1000))` inside a fiber instead of `Wait`.
A sleeping fiber costs nothing, and it can be interrupted while it sleeps.

## NUI

Before: `RegisterNUICallback` answers whatever you hand `cb`, and the page's
`fetch` never learns about an error.

After, in the client script:

```lua
Fx.nui.handle('buy', { input = S.struct { item = S.string, qty = S.int:between(1, 10) } }, function(input)
  return Fx.rpc.call('shop:buy', input)   -- the server's tagged errors reach the page
end)
```

and in the page, with [`@rivolabs/fx-nui`](../packages/fx-nui):

```ts
try {
  const receipt = await fetchNui("buy", { item, qty })
} catch (e) {
  if (isNuiError(e, "InsufficientFunds")) showBroke(e.fields.need)
}
```

## Keeping shapes in sync

Once a payload is shared by Lua, a JS resource and a page, describe it once and
generate all three with [`rivo-fx gen`](../packages/cli).

## Calling Rivo FX from old code

Anything that is still a plain thread can use an effect directly:

```lua
CreateThread(function()
  local ok, hash = pcall(Fx.runAwait, Fx.assets.model('adder', { timeout = 5000 }))
end)
```
