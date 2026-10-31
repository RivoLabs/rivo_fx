# Recipes

Ten complete solutions to common FiveM tasks, written with the Rivo FX Lua API. Each one has a
one-line goal, the full code with the server, client and page parts labelled, and a few lines on
why it is built that way. Every resource below loads the library the usual way:

```lua
-- fxmanifest.lua (add your own scripts below)
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
```

For the API behind each call see [Effects](core-effects.md), [Schema](core-schema.md),
[Net and RPC](net-rpc.md), [FiveM modules](fivem-modules.md), [Data](data.md), [NUI](nui.md) and
[Observability](observability.md). For the error tags see [Errors and gotchas](errors.md).

## 1. A validated shop purchase with a typed OutOfStock error shown in NUI

Goal: the page buys an item through the server, and an `OutOfStock` failure reaches the page as
its own tag with its fields.

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'rivo_fx'
shared_scripts { '@rivo_fx/init.lua', 'shared.lua' }
server_script 'server.lua'
client_script 'client.lua'

ui_page 'web/index.html'
files { 'web/index.html', 'web/app.js', 'web/fx-nui.js' }
```

```lua
-- shared.lua
local S = Fx.S
ShopSchemas = {
  BuyInput = S.struct { item = S.enum { 'water', 'bread', 'phone' }, qty = S.int:between(1, 10) },
  Receipt = S.struct { item = S.string, qty = S.int, paid = S.int },
}
```

```lua
-- server.lua
local OutOfStock = Fx.TaggedError('OutOfStock')
local PRICES = { water = 5, bread = 8, phone = 450 }
local stock = { water = 20, bread = 5, phone = 0 }

-- Take qty from stock in one step, or fail with OutOfStock { item, left }.
local function reserve(item, qty)
  return Fx.suspend(function()
    local left = stock[item]
    if left < qty then return OutOfStock { item = item, left = left }:fail() end
    stock[item] = left - qty
    return Fx.unit
  end)
end

local function unreserve(item, qty)
  return Fx.sync(function() stock[item] = stock[item] + qty end)
end

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

Fx.rpc.register('shop:buy', { input = ShopSchemas.BuyInput, output = ShopSchemas.Receipt, rateLimit = '2/s' },
  function(src, input)
    return Fx.gen(function()
      local fw = Fx.yield(Fx.framework.Framework)
      local cost = PRICES[input.item] * input.qty
      -- InsufficientFunds puts the stock back; nothing interrupts between the two steps
      Fx.yield(reserve(input.item, input.qty)
        :zipRight(fw.removeMoney(src, 'cash', cost, 'shop purchase')
          :tapError(function() return unreserve(input.item, input.qty) end))
        :uninterruptible())
      return { item = input.item, qty = input.qty, paid = cost }
    end)
  end)
```

```lua
-- client.lua
local open -- the fiber that holds NUI focus while the page is open

-- The page's fetchNui('buy', ...) lands here; the server's tagged errors pass through to the page.
Fx.nui.handle('buy', { input = ShopSchemas.BuyInput }, function(input)
  return Fx.rpc.call('shop:buy', input, { timeout = 5000 })
end)

Fx.nui.handle('close', { input = Fx.S.struct {} }, function()
  if open then open:interruptAsFork(0) end
  return true
end)

RegisterCommand('shop', function()
  if open then return end
  open = Fx.runFork(Fx.scoped(Fx.gen(function()
    Fx.yield(Fx.nui.useFocus())                                   -- released when this scope closes
    Fx.yield(Fx.nui.send('open', { items = { 'water', 'bread', 'phone' } }))
    Fx.yield(Fx.never)
  end)):ensuring(Fx.sync(function()
    open = nil
    SendNUIMessage({ type = 'close' })
  end)))
end, false)
```

```js
// web/app.js (page). web/fx-nui.js is the built @rivolabs/fx-nui; `rivo-fx create --template lua-nui` copies it in.
import { fetchNui, isNuiError, onMessage } from './fx-nui.js'

const status = document.getElementById('status')
const show = (text) => { status.textContent = text }

export async function buy(item, qty) {
  try {
    const r = await fetchNui('buy', { item, qty })
    show(`Bought ${r.qty}x ${r.item} for $${r.paid}`)
  } catch (e) {
    if (isNuiError(e, 'OutOfStock')) show(`Only ${e.fields.left} ${e.fields.item} left`)
    else if (isNuiError(e, 'InsufficientFunds')) show(`You need $${e.fields.need}, you have $${e.fields.have}`)
    else if (isNuiError(e, 'RpcInvalidInput')) show(`Check the order: ${e.fields.message}`)
    else if (isNuiError(e, 'RpcTimeout')) show('The shop did not answer')
    else show(`Something went wrong (${e._tag ?? e})`)
  }
}

onMessage('open', ({ items }) => { /* render one button per item that calls buy(item, qty) */ })
window.addEventListener('message', (e) => { if (e.data?.type === 'close') { /* hide the page */ } })
```

```html
<!-- web/index.html -->
<!doctype html>
<html>
  <body>
    <div id="status"></div>
    <script type="module" src="./app.js"></script>
  </body>
</html>
```

Why:
- The schema is checked twice on purpose: `Fx.nui.handle` stops a broken page before a network round trip, and `Fx.rpc.register` stops a cheating client. A failed server check is also reported to `Fx.security`.
- `reserve` checks and takes stock inside one `Fx.suspend`, so two buyers cannot both take the last item. `:uninterruptible()` covers a player who drops between taking stock and paying.
- The page branches on `e._tag` exactly as Lua code uses `:catchTag`. Defects would arrive as `RpcInternalError` with no details.

## 2. A money transfer with Fx.framework and an Fx.db.transaction

Goal: move bank money between two players on any framework, and record both sides in a ledger in
one database transaction.

```sql
-- once
CREATE TABLE bank_ledger (
  id INT AUTO_INCREMENT PRIMARY KEY,
  identifier VARCHAR(64) NOT NULL,
  delta INT NOT NULL,
  counterparty VARCHAR(64) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

```lua
-- fxmanifest.lua: dependencies { 'rivo_fx', 'oxmysql' }
-- server.lua
local S = Fx.S
local SameAccount = Fx.TaggedError('SameAccount')

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

local Transfer = S.struct { to = S.player, amount = S.int:between(1, 1000000) }
local LEDGER = 'INSERT INTO bank_ledger (identifier, delta, counterparty) VALUES (?, ?, ?)'

Fx.rpc.register('bank:transfer', { input = Transfer, rateLimit = '1/s' }, function(src, input)
  return Fx.gen(function()
    if input.to == src then return Fx.yield(SameAccount {}:fail()) end
    local fw = Fx.yield(Fx.framework.Framework)
    local from = Fx.yield(fw.getPlayer(src))
    local to = Fx.yield(fw.getPlayer(input.to))                  -- PlayerNotFound: no character loaded

    -- Take, then give; if giving fails, give the money back. No interruption in between.
    local balance = Fx.yield(fw.removeMoney(src, 'bank', input.amount, 'transfer to ' .. to.identifier)
      :zipLeft(fw.addMoney(input.to, 'bank', input.amount, 'transfer from ' .. from.identifier)
        :tapError(function() return fw.addMoney(src, 'bank', input.amount, 'transfer refund'):orDie() end))
      :uninterruptible())

    -- Both ledger rows or neither. The money has moved, so a ledger failure is logged, not returned.
    Fx.yield(Fx.db.transaction({
      { query = LEDGER, values = { from.identifier, -input.amount, to.identifier } },
      { query = LEDGER, values = { to.identifier, input.amount, from.identifier } },
    })
      :retry(Fx.Schedule.exponential(200):take(3))
      :catchTag('SqlError', function(e)
        return Fx.logError('ledger write failed', {
          message = e.message, from = from.identifier, to = to.identifier, amount = input.amount,
        })
      end))

    return { balance = balance }
  end)
end)
```

```lua
-- client.lua: /transfer <player id> <amount>
RegisterCommand('transfer', function(_, args)
  local to, amount = tonumber(args[1]), tonumber(args[2])
  Fx.runFork(Fx.rpc.call('bank:transfer', { to = to, amount = amount }, { timeout = 5000 })
    :tap(function(r) print(('sent; your bank balance is $%d'):format(r.balance)) end)
    :catchTags {
      InsufficientFunds = function(e) print(('you need $%d, you have $%d'):format(e.need, e.have)) return Fx.unit end,
      PlayerNotFound = function() print('that player has no character loaded') return Fx.unit end,
      SameAccount = function() print('you cannot send money to yourself') return Fx.unit end,
      RpcInvalidInput = function(e) print('bad transfer: ' .. e.message) return Fx.unit end,
      RpcTimeout = function() print('the bank did not answer') return Fx.unit end,
    })
end, false)
```

Why:
- On ESX, QBCore and Qbox the framework owns the balance in memory and saves it itself, so money moves through `Fx.framework`, never through SQL. The database holds the ledger, and `Fx.db.transaction` makes its two rows atomic.
- `removeMoney` fails with `InsufficientFunds { need, have }` instead of going negative. `S.player` rejects ids of players who are not connected before the handler runs.
- The refund runs only if the deposit fails, and `:orDie()` turns a failed refund into a logged defect (the client gets `RpcInternalError`) rather than a silent loss.

## 3. A vehicle that is deleted when the player drops

Goal: spawn a server-side vehicle for a player and have it deleted automatically when that player
leaves (or the resource stops).

```lua
-- server.lua
local S = Fx.S
local Spawn = S.struct { model = S.enum { 'adder', 'sultan', 'faggio' } }

Fx.rpc.register('garage:spawn', { input = Spawn, rateLimit = '1/s' }, function(src, input)
  return Fx.gen(function()
    local ped = GetPlayerPed(src)
    -- spawnVehicle needs a Scope; the player's scope closes on playerDropped and deletes it
    local veh = Fx.yield(Fx.player.extend(src,
      Fx.entity.spawnVehicle(input.model, GetEntityCoords(ped), GetEntityHeading(ped), { timeout = 5000 })))
    return NetworkGetNetworkIdFromEntity(veh)
  end)
end)
```

```lua
-- client.lua: /car [model]
RegisterCommand('car', function(_, args)
  Fx.runFork(Fx.gen(function()
    local netId = Fx.yield(Fx.rpc.call('garage:spawn', { model = args[1] or 'adder' }, { timeout = 8000 }))
    local veh = Fx.yield(Fx.entity.fromNetId(netId, { timeout = 5000 }))
    TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
  end):catchTags {
    RpcInvalidInput = function(e) print('unknown model: ' .. e.message) return Fx.unit end,
    SpawnFailed = function() print('the vehicle did not spawn') return Fx.unit end,
    NetIdTimeout = function() print('the vehicle never reached this client') return Fx.unit end,
  })
end, false)
```

Why:
- `Fx.entity.spawnVehicle` acquires the entity with a release that deletes it. `Fx.player.extend(src, eff)` runs it in the player's scope, so the release runs on `playerDropped`, and every open scope also closes on resource stop.
- The server owns the entity, so a client cannot keep it alive or spawn models outside the `S.enum` list.
- The client waits for the network id with a timeout instead of looping on `NetworkDoesNetworkIdExist`.

## 4. Security events batched to a Discord webhook

Goal: post rejected payloads and unknown RPCs to a Discord channel, at most one message per batch of
20 or per 10 seconds.

```lua
-- server.lua; server.cfg: set anticheat:webhook "https://discord.com/api/webhooks/..."
local WebhookFailed = Fx.TaggedError('WebhookFailed')

local function line(ev)
  local msg = ev.message and (': ' .. tostring(ev.message):sub(1, 120)) or ''
  return ('`%s` player %s on `%s`%s'):format(ev.kind, tostring(ev.source), tostring(ev.name), msg)
end

local function post(url, batch)
  local lines = {}
  for i, ev in ipairs(batch) do lines[i] = line(ev) end
  return Fx.async(function(resume)
    PerformHttpRequest(url, function(status)
      if status >= 200 and status < 300 then resume(Fx.unit)
      else resume(Fx.fail(WebhookFailed { status = status })) end
    end, 'POST', json.encode({ content = table.concat(lines, '\n') }), { ['Content-Type'] = 'application/json' })
  end)
end

Fx.runFork(Fx.gen(function()
  local url = Fx.yield(Fx.config.string('anticheat:webhook'))   -- ConfigError when unset
  Fx.yield(Fx.security.stream()
    :filter(function(ev) return ev.kind ~= 'rate_limited' end)
    :groupedWithin(20, 10000)
    :runForEach(function(batch)
      return post(url, batch):timeout(5000):catchAll(function(e)
        return Fx.logWarn('webhook post failed', { error = e._tag, status = e.status })
      end)
    end))
end))
```

Why:
- `groupedWithin(20, 10000)` emits a batch when 20 events have piled up, or 10 s after the first event of a batch, whichever comes first, so a flood becomes a few posts instead of hundreds.
- `runForEach` handles one batch at a time. While a post is in flight, new events wait in the stream's buffer (1024 by default, oldest dropped first). Rate-limit hits are filtered out because a flood produces one per message.
- `Fx.security.stream()` sees this resource's events only. To watch every resource, stream the local event instead: `Fx.Stream.event('rivo_fx:security', function(ev, resource) ev.resource = resource return ev end)`.

## 5. A retrying external HTTP call with a timeout

Goal: fetch JSON from an external API, give each attempt 3 s, retry server errors and timeouts with
exponential backoff, and decode the body with a schema.

```lua
-- server.lua
local S = Fx.S
local HttpError = Fx.TaggedError('HttpError')
local Price = S.struct { usd = S.number }

local function httpGet(url)
  return Fx.async(function(resume)
    PerformHttpRequest(url, function(status, body)
      if status >= 200 and status < 300 then resume(Fx.succeed(body))
      else resume(Fx.fail(HttpError { url = url, status = status })) end
    end, 'GET', '', { Accept = 'application/json' })
  end)
end

-- Retry timeouts and anything but a 4xx (429 Too Many Requests is retried).
local function retryable(e)
  if e._tag == 'TimeoutError' then return true end
  if e._tag ~= 'HttpError' then return false end
  return e.status == 429 or e.status < 400 or e.status >= 500
end

local function fetchPrice()
  return httpGet('https://api.example.com/price')
    :timeout(3000)                                                       -- TimeoutError { timeoutMs }
    :retry(Fx.Schedule.exponential(250):jittered():whileInput(retryable):take(4))
    :flatMap(function(body)
      local ok, decoded = pcall(json.decode, body)
      return Price:decode(ok and decoded or nil)                         -- ParseError { message }
    end)
end

RegisterCommand('price', function()
  Fx.runFork(fetchPrice()
    :tap(function(p) print(('price: $%.2f'):format(p.usd)) end)
    :catchAll(function(e) return Fx.logWarn('price lookup failed', { error = Fx.inspect(e) }) end))
end, true)
```

Why:
- `:timeout(3000)` sits inside `:retry(...)`, so each attempt gets its own 3 s, and a timeout is just another failure the schedule can retry. Put a second `:timeout` outside the retry to cap the total.
- The schedule reads as written: delays of about 250, 500, 1000 and 2000 ms (randomised by 0.8 to 1.2), only while the error is retryable, at most 4 retries. After that the last error is returned.
- `PerformHttpRequest` cannot be aborted. When an attempt times out, its late callback is ignored, so it can never resume the next attempt.

## 6. A per-player cooldown

Goal: let each player claim a reward once every 30 minutes, and tell them how long to wait.

```lua
-- server.lua
local S = Fx.S
local OnCooldown = Fx.TaggedError('OnCooldown')
local lastUsed = {} -- src -> GetGameTimer() of the last claim
local watched = {}  -- src -> true once an onDrop cleanup is registered

---Run eff unless src ran it less than ms ago. A failed eff does not use up the cooldown.
local function cooldown(src, ms, eff)
  return Fx.suspend(function()
    local now, last = GetGameTimer(), lastUsed[src]
    if last and now - last < ms then
      return OnCooldown { remainingMs = ms - (now - last) }:fail()
    end
    if not watched[src] then
      watched[src] = true
      Fx.player.onDrop(src, function() lastUsed[src], watched[src] = nil, nil end)
    end
    lastUsed[src] = now
    return eff:tapError(function() return Fx.sync(function() lastUsed[src] = last end) end)
  end)
end

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

Fx.rpc.register('reward:claim', { input = S.struct {} }, function(src)
  return cooldown(src, 30 * 60 * 1000, Fx.gen(function()
    local fw = Fx.yield(Fx.framework.Framework)
    return Fx.yield(fw.addMoney(src, 'cash', 250, 'reward'))
  end))
end)
```

```lua
-- client.lua
RegisterCommand('reward', function()
  Fx.runFork(Fx.rpc.call('reward:claim', {}, { timeout = 5000 })
    :tap(function(cash) print(('+$250, cash now $%d'):format(cash)) end)
    :catchTag('OnCooldown', function(e)
      print(('come back in %d minutes'):format(math.ceil(e.remainingMs / 60000)))
      return Fx.unit
    end))
end, false)
```

Why:
- The check and the update happen in one `Fx.suspend`, so two requests in the same frame cannot both pass.
- A cooldown is a game rule the player should see, so it is a tagged error with `remainingMs`. The RPC's `rateLimit` (10/s by default) is a different thing: it protects the server from floods and reports `rate_limited` security events.
- `Fx.player.onDrop` forgets the timer when the player leaves, so the table does not grow.

## 7. A proximity marker with Fx.tick.whileNear

Goal: draw a marker and a help prompt near a shop, paying for per-frame work only while the player
is close.

```lua
-- client.lua
local SHOP = vector3(25.7, -1347.3, 29.5)
local marker

local function drawShop(distance)
  DrawMarker(1, SHOP.x, SHOP.y, SHOP.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.5, 1.5, 0.5,
    30, 144, 255, 120, false, false, 2, false, nil, nil, false)
  if distance < 1.5 then
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName('Press ~INPUT_CONTEXT~ to shop')
    EndTextCommandDisplayHelp(0, false, true, -1)
    if IsControlJustReleased(0, 38) then ExecuteCommand('shop') end
  end
end

local function start()
  marker = Fx.runFork(Fx.tick.whileNear(SHOP, 15.0, drawShop, { checkMs = 1000 }))
end

-- /shopmarker toggles it, to show that stopping is one call
RegisterCommand('shopmarker', function()
  if marker then
    marker:interruptAsFork(0)
    marker = nil
  else
    start()
  end
end, false)

start()
```

Why:
- While the player is farther than 15 m, the distance is checked once a second (`checkMs`), so the marker costs almost nothing away from the shop. Within range, `drawShop` runs every frame with the current distance.
- The loop is a fiber: interrupting it, or the resource stopping, ends the frame thread. There is no `while true do Wait(0) end` to forget about.
- If `drawShop` raises, the effect fails with that defect and the error is logged as an unhandled fiber failure (visible in `/fxdev` Failures) instead of silently killing a thread.

## 8. A service provided by a Layer and swapped in tests

Goal: put payment behind a `Bank` service, use the framework in production, and test the purchase
logic with a fake bank.

```lua
-- server.lua
local S = Fx.S
Bank = Fx.Tag('Bank')
NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')

-- Production: Bank on top of the running framework.
local BankLive = Fx.Layer.effect(Bank, Fx.gen(function()
  local fw = Fx.yield(Fx.framework.Framework)
  return {
    pay = function(src, amount, reason)
      return fw.removeMoney(src, 'bank', amount, reason):asVoid()
        :catchTag('InsufficientFunds', function(e)
          return NotEnoughMoney { have = e.have, need = e.need }:fail()
        end)
    end,
  }
end)):provide(Fx.framework.auto)

-- The logic only knows about Bank.
function BuyLicense(src)
  return Fx.gen(function()
    local bank = Fx.yield(Bank)
    Fx.yield(bank.pay(src, 500, 'weapon license'))
    return true
  end)
end

Fx.setRuntime(Fx.Runtime.make(BankLive))
Fx.rpc.register('license:buy', { input = S.struct {} }, function(src) return BuyLicense(src) end)
```

```lua
-- server_test.lua: load it only on a dev server (server_script 'server_test.lua' after server.lua)
local function FakeBank(balance)
  local paid = {}
  local layer = Fx.Layer.succeed(Bank, {
    pay = function(_, amount)
      return Fx.suspend(function()
        if amount > balance then return NotEnoughMoney { have = balance, need = amount }:fail() end
        balance = balance - amount
        paid[#paid + 1] = amount
        return Fx.unit
      end)
    end,
  })
  return layer, paid
end

RegisterCommand('test_license', function()
  CreateThread(function()
    local rich, paid = FakeBank(1000)
    assert(Fx.runAwait(BuyLicense(1):provide(rich)) == true)
    assert(paid[1] == 500, 'charged 500')

    local poor = FakeBank(100)
    local exit = Fx.runAwait(BuyLicense(1):provide(poor):exit())
    assert(Fx.Cause.failureOption(exit.cause)._tag == 'NotEnoughMoney')
    print('license tests passed')
  end)
end, true)
```

Why:
- `Fx.yield(Bank)` asks for whatever implementation is provided. The RPC gets `BankLive` from `Fx.setRuntime`; the test gets `FakeBank` from `:provide(layer)`. `BuyLicense` does not change.
- `BankLive` maps the framework's `InsufficientFunds` to the service's own `NotEnoughMoney`, so callers and tests depend on one error, whatever the framework.
- `Fx.runAwait` raises on failure, so the second case uses `:exit()` to inspect the failure as a value. A missing service is a defect: `Service not found: Bank. Provide it with :provide(layer) or :provideService(tag, impl).`

## 9. Tracing an RPC and reading it in /fxdev

Goal: see one trace from a client command through the server handler, with timings, attributes
and the log lines that belong to it.

```cfg
# server.cfg
ensure rivo_fx
ensure bank
add_ace group.admin rivo_fx.devtools allow
add_principal identifier.license:your_license_here group.admin
```

```lua
-- server.lua
local S = Fx.S
local Lookup = Fx.metrics.histogram('bank_lookup_ms', { help = 'Balance lookups', buckets = { 1, 5, 25, 100 } })

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

Fx.rpc.register('bank:balance', { input = S.struct { account = S.enum { 'cash', 'bank' } } }, function(src, input)
  return Fx.gen(function()
    Fx.yield(Fx.annotateCurrentSpan('account', input.account))       -- on the rpc.server span
    local fw = Fx.yield(Fx.framework.Framework)
    local balance = Fx.yield(fw.getMoney(src, input.account):withSpan('framework.getMoney'))
    Fx.yield(Fx.logInfo('balance read', { account = input.account })) -- logged with traceId and spanId
    return balance
  end):trackDuration(Lookup)
end)
```

```lua
-- client.lua
RegisterCommand('balance', function()
  Fx.runFork(Fx.rpc.call('bank:balance', { account = 'bank' }, { timeout = 5000 })
    :tap(function(balance) print('bank balance', balance) end)
    :withSpan('ui.balance', { attributes = { source = 'command' } }))
end, false)
```

In game, run `/balance`, then `/fxdev traces`. The Traces view shows one trace as a waterfall,
roughly:

```
ui.balance                     client  bank
  rpc.client bank:balance      client  bank   rpc.name, rpc.target
    rpc.server bank:balance    server  bank   rpc.name, rpc.caller, player, account
      framework.getMoney       server  bank
```

Why:
- `Fx.rpc.call` sends its span as a W3C traceparent, and the server handler's `rpc.server` span continues it, so both sides share one trace id. A JS resource on either end joins the same trace, but only Lua resources show up in `/fxdev`.
- `/fxdev` asks the server for data only while it is open, and the server checks the `rivo_fx.devtools` ACE on every request. The `Fx.logInfo` line carries `traceId` and `spanId`. If the handler fails, its `rpc.server` span is marked as an error with the tag, and a defect is also logged to the Failures view.
- The client and server clocks are separate. When a span from one side falls outside its parent from the other, the waterfall moves it inside the parent and marks it with `~`. Use the `rpc.client` span (or `rivo_fx_rpc_call_ms`) for round-trip time, not start times compared across sides.

## 10. Moving an ox_lib callback without breaking old callers

Goal: move a `lib.callback.register` handler to `Fx.rpc.register` while old
`lib.callback.await` callers keep working, then move the callers one by one.

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependencies { 'ox_lib', 'rivo_fx' }
shared_scripts { '@ox_lib/init.lua', '@rivo_fx/init.lua' }
server_script 'server.lua'
client_script 'client.lua'
```

```lua
-- server.lua
-- before:
--   lib.callback.register('garage:list', function(source, kind) return listVehicles(source, kind) end)
local S = Fx.S
local garages = {} -- src -> { { plate, model, kind } }

Fx.rpc.register('garage:list', {
  input = S.enum { 'car', 'boat' },          -- old callers pass the kind as their first argument
  output = S.array(S.struct { plate = S.string, model = S.string, kind = S.string }),
  rateLimit = '5/s',
  libCallback = true,                        -- also answer lib.callback callers
}, function(src, kind)
  local out = {}
  for _, v in ipairs(garages[src] or {}) do
    if v.kind == kind then out[#out + 1] = v end
  end
  return out
end)
```

```lua
-- client.lua
-- An old caller, unchanged: still validated and rate limited.
RegisterCommand('cars_old', function()
  local cars = lib.callback.await('garage:list', false, 'car')
  print('cars (old):', cars and #cars or 'rejected')
end, false)

-- A moved caller: a timeout and typed errors.
RegisterCommand('cars', function()
  Fx.runFork(Fx.rpc.call('garage:list', 'car', { timeout = 5000 })
    :tap(function(cars) print('cars:', #cars) end)
    :catchTags {
      RpcInvalidInput = function(e) print('bad request: ' .. e.message) return Fx.unit end,
      RpcTimeout = function() print('the garage did not answer') return Fx.unit end,
    })
end, false)

-- A callback that still lives in ox_lib, called from Fx.
RegisterCommand('impound', function()
  Fx.runFork(Fx.compat.libCallback('impound:list', 'car', Fx.compat.opts { timeout = 3000 })
    :tap(function(list) print('impounded:', list and #list or 0) end)
    :catchTag('RpcTimeout', function() print('impound did not answer') return Fx.unit end))
end, false)
```

Why:
- With `libCallback = true` the same handler serves both protocols, with the same schema and the same rate-limit bucket. Old callers get `nil` when their input is rejected (and the server logs a security event); new callers get `RpcInvalidInput`.
- An ox_lib callback receives only its first argument as the input. If old callers pass several positional arguments, keep a wrapper until they are moved, or change them to pass one table.
- Once no `lib.callback.await('garage:list', ...)` remains, delete `libCallback = true`. `Fx.compat.libCallback` covers the other direction: calling a handler that has not moved yet, with a timeout that fails `RpcTimeout`.
