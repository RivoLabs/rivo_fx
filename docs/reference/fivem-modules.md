# FiveM modules

This page covers the Rivo FX modules that wrap FiveM's game and server lifecycle: per-player scopes (`Fx.player`), resource stop (`Fx.onStop`, `Fx.resourceScope`), typed convars and config files (`Fx.config`), streamed asset loading (`Fx.assets`), entities (`Fx.entity`) and frame loops (`Fx.tick`). Use them instead of hand-written `while not HasModelLoaded() do Wait(0) end` loops, `playerDropped` bookkeeping and `GetConvar` parsing. Every function here returns an effect unless noted, so nothing happens until you run it (`Fx.yield` inside `Fx.gen`, `Fx.runFork`, `Fx.runAwait`); see [Effects](core-effects.md).

All modules load lazily the first time you touch `Fx.<module>`. Scoped helpers (`use*`, `spawn*`, `StateKey:watch`, `Fx.nui.useFocus`) need a `Scope` service, which you get from `Fx.scoped`, a scoped layer, `Fx.player.extend` or `Fx.resourceScope:extend`; without one the effect dies with `Service not found: Scope`. See [Resources and scopes](core-resources.md).

| Module | Side |
|---|---|
| `Fx.player` | server |
| `Fx.onStop`, `Fx.resourceScope` | both |
| `Fx.config` | both (client sees replicated convars only) |
| `Fx.assets`, `Fx.poll` | client |
| `Fx.entity` | both, except `requestControl` (client only) |
| `Fx.tick` | `everyFrame` and `whileTrue` both, `whileNear` client |

## Player scopes

`Fx.player` gives every connected player a [Scope](core-resources.md) that closes when the player drops. Anything attached to it (fibers, finalizers, scoped resources) is released then. `Fx.net.handle` and `Fx.rpc.register` handler fibers on the server are attached to the sender's player scope automatically, so a drop interrupts them (see [Net and RPC](net-rpc.md)).

### Fx.player.scope(src)

```lua
Fx.player.scope(src: integer|string) -> Fx.ScopeObject
-- src: server id (converted with tonumber)
```

- **Side:** server.
- **Parameters:** `src`, the player's server id.
- **Returns:** the player's scope object, created on first use. Not an effect.
- **Fails with:** never.
- **Notes:**
  - The scope closes on `playerDropped` with an interrupt exit. The close runs on its own fiber, so finalizers may suspend (save to the database, call an RPC).
  - After a drop, the next call for the same id creates a fresh scope. Calling it for a player who has already left creates a scope that only closes when that id drops again or the resource stops.
  - The object has the scope methods `:addFinalizer(fin)`, `:close(exit)`, `:fork()` and `:extend(eff)` ([Resources and scopes](core-resources.md)).
  - On the client nothing closes it except resource stop.

```lua
local s = Fx.player.scope(source)
Fx.runFork(s:addFinalizer(function()
  return Fx.logInfo('session ended', { player = source })
end))
```

### Fx.player.extend(src, eff)

```lua
Fx.player.extend(src: integer, eff: Fx.Effect<A, E>) -> Fx.Effect<A, E>
```

- **Side:** server.
- **Parameters:** `src`, the player's server id; `eff`, an effect that may use `Scope`.
- **Returns:** `eff` with the player's scope provided as its `Scope` service.
- **Fails with:** whatever `eff` fails with.
- **Notes:** resources `eff` acquires (`Fx.acquireRelease`, `Fx.entity.spawnVehicle`, `StateKey:watch`) are released when the player drops, not when `eff` ends. `eff` itself is not interrupted by the drop; use `Fx.player.fork` for that.

```lua
-- a rental car that is deleted when the renter disconnects
Fx.rpc.register('rental:spawn', { input = S.struct {} }, function(src)
  local ped = GetPlayerPed(src)
  return Fx.player.extend(src, Fx.entity.spawnVehicle('faggio', GetEntityCoords(ped), GetEntityHeading(ped)))
    :map(function(veh) return NetworkGetNetworkIdFromEntity(veh) end)
end)
```

### Fx.player.fork(src, eff, opts)

```lua
Fx.player.fork(src: integer, eff: Fx.Effect<any, any>, opts?: { onExit?: fun(exit: Fx.Exit), context?: table }) -> Fx.Fiber
-- opts: passed to Fx.runFork
```

- **Side:** server.
- **Parameters:** `src`, the player's server id; `eff`, the effect to run; `opts`, the same options as `Fx.runFork`.
- **Returns:** the running fiber (not an effect; it starts right away).
- **Fails with:** never itself. The fiber is interrupted when the player drops; if it ends on its own first, it is detached from the scope.
- **Notes:** the fiber does not get the player's scope as its `Scope` service. Combine with `Fx.player.extend` if it acquires resources.

```lua
AddEventHandler('playerJoining', function()
  local src = source
  Fx.player.fork(src, Fx.gen(function()
    while true do
      Fx.yield(Fx.sleep(60000))
      Fx.yield(Payroll.paySalary(src))
    end
  end))
end)
```

### Fx.player.onDrop(src, fin)

```lua
Fx.player.onDrop(src: integer, fin: fun()|Fx.Effect<any, any>)
```

- **Side:** server.
- **Parameters:** `src`, the player's server id; `fin`, a plain function (called with no arguments) or an effect.
- **Returns:** nothing. Not an effect; the finalizer is registered immediately.
- **Fails with:** never. A finalizer that fails or raises is logged as a defect and the other finalizers still run.
- **Notes:** finalizers run last added first. They also run if the resource stops while the player is online, and then they must be synchronous (see [What closes on resource stop](#what-closes-on-resource-stop)).

```lua
Fx.player.onDrop(src, Fx.db.update('UPDATE players SET last_seen = NOW() WHERE id = ?', { charId }))
Fx.player.onDrop(src, function() activeJobs[src] = nil end)
```

## Resource lifecycle

### Fx.onStop(fin)

```lua
Fx.onStop(fin: fun()|Fx.Effect<any, any>)
```

- **Side:** both.
- **Parameters:** `fin`, a plain function (called with no arguments) or an effect.
- **Returns:** nothing. Not an effect; the finalizer is added to `Fx.resourceScope` right away.
- **Fails with:** never. A finalizer that fails is reported as `scope finalizer on stop` and the rest still run.
- **Notes:** runs when this resource stops. The stop handler has no later tick, so the finalizer must finish synchronously: an effect that sleeps, waits on a fiber or makes an async call (`Fx.db.*`, `Fx.rpc.call`) fails with `Fx.runSync hit an async effect` and is skipped.

```lua
Fx.onStop(function()
  for _, blip in pairs(shopBlips) do RemoveBlip(blip) end
end)
```

### Fx.resourceScope

```lua
---@type Fx.ScopeObject
Fx.resourceScope
```

- **Side:** both.
- **Returns:** the scope of this resource, created when `init.lua` loads. A value, not a function.
- **Fails with:** never.
- **Notes:** closes when the resource stops. Use `Fx.resourceScope:extend(eff)` to tie scoped resources to the resource's lifetime, or `Fx.resourceScope:fork()` for a child scope you can close earlier.

```lua
-- client: the shop ped exists for as long as the resource runs
Fx.runFork(Fx.resourceScope:extend(
  Fx.entity.spawnPed('s_m_m_shopkeep_01', vector3(24.5, -1346.6, 28.5), 270.0, { networked = false })))
```

### What closes on resource stop

When `onResourceStop` fires for this resource, Rivo FX:

1. Interrupts every root fiber (fibers started with `Fx.runFork`, `Fx.runAwait`, and so on).
2. Closes every open scope, newest first, synchronously, with an interrupt exit. That includes `Fx.scoped` scopes inside running fibers, runtime layer scopes (`Fx.Runtime.make`, `Fx.Layer.scoped`), player scopes and `Fx.resourceScope` (one of the oldest, so it closes near the end).

So on stop, scoped models and dictionaries are released, scoped entities are deleted, `StateKey:watch` handlers are removed, NUI focus taken with `Fx.nui.useFocus` is released, and `Fx.onStop` / `Fx.player.onDrop` finalizers run. Finalizers that need to wait are reported and skipped. The e2e suite checks that a scoped finalizer, a scoped layer's finalizer and an `Fx.onStop` function all run on stop.

## Configuration

`Fx.config` reads convars and config files into typed values. Every reader is an effect that fails with `ConfigError` instead of handing you a `nil` or a string you forgot to convert.

`Fx.config.ConfigError` is the error class. Fields: `name` (the convar name or file path) and `message`. See [Errors](errors.md).

All convar readers share these rules:

- A convar that is unset or set to `""` is missing. Missing with a default succeeds with the default (returned as given, not parsed or checked). Missing without a default fails with `ConfigError { message = 'convar <name> is not set' }`.
- A value that does not parse fails with `ConfigError { message = 'convar <name>: expected <kind>, got "<raw>"' }`.
- They read `GetConvar`, which on the client only sees replicated convars (`setr`).
- They read the convar each time the effect runs, so re-running picks up a changed value.

### Fx.config.string(name, default)

```lua
Fx.config.string(name: string, default?: string) -> Fx.Effect<string, ConfigError>
```

- **Side:** both.
- **Parameters:** `name`, the convar; `default`, used when it is missing.
- **Returns:** the raw string.
- **Fails with:** `ConfigError` when missing without a default.

```lua
local webhook = Fx.yield(Fx.config.string('garage:webhook'))
```

### Fx.config.number(name, default)

```lua
Fx.config.number(name: string, default?: number) -> Fx.Effect<number, ConfigError>
```

- **Side:** both.
- **Returns:** the value parsed with `tonumber`.
- **Fails with:** `ConfigError` when missing without a default, or when it is not a number (NaN is refused).

```lua
local tax = Fx.yield(Fx.config.number('shop:taxRate', 0.08))
```

### Fx.config.int(name, default)

```lua
Fx.config.int(name: string, default?: integer) -> Fx.Effect<integer, ConfigError>
```

- **Side:** both.
- **Returns:** an integer. `"7"` and `"7.0"` both give `7`.
- **Fails with:** `ConfigError` when missing without a default, or when the value is not an integer (`"abc"`, `"7.5"`). Message example: `convar garage:maxCars: expected integer, got "abc"`.

```lua
local maxCars = Fx.yield(Fx.config.int('garage:maxCars', 5))
```

### Fx.config.bool(name, default)

```lua
Fx.config.bool(name: string, default?: boolean) -> Fx.Effect<boolean, ConfigError>
```

- **Side:** both.
- **Returns:** `true` for `true`, `1`, `yes`, `on`; `false` for `false`, `0`, `no`, `off`. Case-insensitive.
- **Fails with:** `ConfigError` when missing without a default, or for any other value.
- **Notes:** a default of `false` works (only `nil` means "no default").

```lua
local debug = Fx.yield(Fx.config.bool('garage:debug', false))
```

### Fx.config.enum(name, values, default)

```lua
Fx.config.enum(name: string, values: string[], default?: string) -> Fx.Effect<string, ConfigError>
```

- **Side:** both.
- **Parameters:** `values`, the allowed strings.
- **Returns:** the convar's value, which is one of `values`.
- **Fails with:** `ConfigError` when missing without a default, or when the value is not in `values` (`expected one of a, b, c`). The match is case-sensitive.

```lua
local mode = Fx.yield(Fx.config.enum('garage:parking', { 'public', 'private', 'off' }, 'public'))
```

### Fx.config.json(name, schema, default)

```lua
Fx.config.json(name: string, schema: Fx.Schema, default?: any) -> Fx.Effect<any, ConfigError>
```

- **Side:** both.
- **Parameters:** `schema`, checked against the decoded JSON ([Schema](core-schema.md)).
- **Returns:** the value as the schema outputs it (unknown struct keys stripped, transforms applied).
- **Fails with:** `ConfigError` when missing without a default, when the JSON does not decode, decodes to `null`, or fails the schema. The message is `expected JSON matching the schema, got "<raw>"`; the schema's own message is not included.

```lua
local Spots = S.array(S.struct { x = S.number, y = S.number, z = S.number })
local spots = Fx.yield(Fx.config.json('garage:spots', Spots, {}))
```

```cfg
set garage:spots '[{"x":215.8,"y":-810.1,"z":30.7}]'
```

### Fx.config.struct(fields)

```lua
Fx.config.struct(fields: table<string, Fx.Effect<any, any>>) -> Fx.Effect<table, ConfigError>
```

- **Side:** both.
- **Parameters:** `fields`, a table of name to config effect (any effects work).
- **Returns:** a table with the same keys and the read values.
- **Fails with:** the first `ConfigError`. Fields are read one after another in `pairs` order and reading stops at the first failure, so only one problem is reported per run (the source comment says all are reported; the code does not do that).
- **Notes:** this is `Fx.all(fields)`.

```lua
local Config = Fx.config.struct {
  maxCars = Fx.config.int('garage:maxCars', 5),
  webhook = Fx.config.string('garage:webhook'),
  debug = Fx.config.bool('garage:debug', false),
}

Fx.runFork(Fx.gen(function()
  local cfg = Fx.yield(Config)
  print(('garage: up to %d cars'):format(cfg.maxCars))
end))
```

### Fx.config.file(path, schema, opts)

```lua
Fx.config.file(path: string, schema: Fx.Schema, opts?: { resource?: string }) -> Fx.Effect<any, ConfigError>
-- path: path inside the resource, e.g. 'config.json' or 'config/shops.lua'
-- opts.resource: defaults to the current resource
```

- **Side:** both (the file must be loadable with `LoadResourceFile` on that side, so list it in `files` for the client).
- **Parameters:** `path`; `schema`, checked against the loaded data; `opts.resource`, the resource to read from.
- **Returns:** the data as the schema outputs it.
- **Fails with:** `ConfigError { name = path }` with message `<res>/<path> not found`, `invalid JSON`, the Lua load or runtime error, or the schema's message.
- **Notes:**
  - A path ending in `.json` is decoded as JSON. Any other path is loaded as Lua text that must `return` a table.
  - Lua config files run with an empty environment: no globals (`vector3`, `print`, `GetConvar`) are available. Use plain tables and numbers.

```lua
-- config/shops.lua
return {
  { name = 'Ammu-Nation', x = 22.0, y = -1107.2, z = 29.8 },
}
```

```lua
local Shops = S.array(S.struct { name = S.string, x = S.number, y = S.number, z = S.number })
local shops = Fx.yield(Fx.config.file('config/shops.lua', Shops))
```

## Assets

`Fx.assets` loads streamed assets with a timeout and typed errors. Each loader has a scoped `use*` twin that releases the asset when the current scope closes.

Shared rules:

- `opts.timeout` is in milliseconds, default `10000`.
- The asset is polled once per frame until it loads.
- `AssetTimeout { kind, name, timeoutMs }` when it does not load in time. `name` is what you passed.
- `AssetNotFound { kind, name }` is only checked for models (`IsModelInCdimage` and `IsModelValid`) and anim dictionaries (`DoesAnimDictExist`). A wrong name for any other kind ends in `AssetTimeout`.
- `use*` variants need a `Scope`. They release the asset (`SetModelAsNoLongerNeeded`, `RemoveAnimDict`, ...) when the scope closes. The plain loaders never release.
- `kind` is one of `model`, `animDict`, `animSet`, `ptfx`, `textureDict`, `scaleform`, `audioBank`.

The error classes are `Fx.assets.AssetNotFound` and `Fx.assets.AssetTimeout`. See [Errors](errors.md).

### Fx.assets.model(model, opts)

```lua
Fx.assets.model(model: string|integer, opts?: { timeout?: integer }) -> Fx.Effect<integer, AssetNotFound|AssetTimeout>
-- model: name or hash
```

- **Side:** client.
- **Parameters:** `model`, a name (hashed with `joaat`) or a hash; `opts.timeout`.
- **Returns:** the model hash.
- **Fails with:** `AssetNotFound`, `AssetTimeout`.
- **Notes:** you release it yourself with `SetModelAsNoLongerNeeded`, or use `useModel`.

```lua
CreateThread(function()
  local ok, hash = pcall(Fx.runAwait, Fx.assets.model('adder', { timeout = 5000 }))
  if not ok then return print('could not load adder: ' .. tostring(hash._tag)) end
  local veh = CreateVehicle(hash, 215.8, -810.1, 30.7, 0.0, true, false)
  SetModelAsNoLongerNeeded(hash)
end)
```

### Fx.assets.useModel(model, opts)

```lua
Fx.assets.useModel(model: string|integer, opts?: { timeout?: integer }) -> Fx.Effect<integer, AssetNotFound|AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the model hash.
- **Fails with:** `AssetNotFound`, `AssetTimeout`.
- **Notes:** calls `SetModelAsNoLongerNeeded` when the scope closes.

```lua
Fx.runFork(Fx.scoped(Fx.gen(function()
  local hash = Fx.yield(Fx.assets.useModel('prop_tool_box_04'))
  local obj = CreateObject(hash, 0.0, 0.0, 72.0, false, false, false)
  -- ...
end)))
```

### Fx.assets.animDict(dict, opts)

```lua
Fx.assets.animDict(dict: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetNotFound|AssetTimeout>
```

- **Side:** client.
- **Returns:** the dictionary name.
- **Fails with:** `AssetNotFound` (when `DoesAnimDictExist` is false), `AssetTimeout`.

```lua
local dict = Fx.yield(Fx.assets.animDict('mini@repair'))
TaskPlayAnim(PlayerPedId(), dict, 'fixing_a_ped', 8.0, -8.0, -1, 1, 0, false, false, false)
```

### Fx.assets.useAnimDict(dict, opts)

```lua
Fx.assets.useAnimDict(dict: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetNotFound|AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the dictionary name.
- **Fails with:** `AssetNotFound`, `AssetTimeout`.
- **Notes:** calls `RemoveAnimDict` when the scope closes.

```lua
local repair = Fx.scoped(Fx.gen(function()
  local dict = Fx.yield(Fx.assets.useAnimDict('mini@repair'))
  TaskPlayAnim(PlayerPedId(), dict, 'fixing_a_ped', 8.0, -8.0, 5000, 1, 0, false, false, false)
  Fx.yield(Fx.sleep(5000))
end))
```

### Fx.assets.animSet(set, opts)

```lua
Fx.assets.animSet(set: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
```

- **Side:** client.
- **Returns:** the anim set name.
- **Fails with:** `AssetTimeout` (no existence check).

```lua
local set = Fx.yield(Fx.assets.animSet('move_m@drunk@verydrunk'))
SetPedMovementClipset(PlayerPedId(), set, 0.2)
```

### Fx.assets.useAnimSet(set, opts)

```lua
Fx.assets.useAnimSet(set: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the anim set name.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `RemoveAnimSet` when the scope closes.

```lua
Fx.yield(Fx.assets.useAnimSet('move_m@injured'))
```

### Fx.assets.ptfx(asset, opts)

```lua
Fx.assets.ptfx(asset: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
```

- **Side:** client.
- **Returns:** the particle asset name (`RequestNamedPtfxAsset` / `HasNamedPtfxAssetLoaded`).
- **Fails with:** `AssetTimeout`.

```lua
local fx = Fx.yield(Fx.assets.ptfx('core'))
UseParticleFxAsset(fx)
StartParticleFxNonLoopedAtCoord('ent_sht_electrical_box', x, y, z, 0.0, 0.0, 0.0, 1.0, false, false, false)
```

### Fx.assets.usePtfx(asset, opts)

```lua
Fx.assets.usePtfx(asset: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the particle asset name.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `RemoveNamedPtfxAsset` when the scope closes.

```lua
Fx.yield(Fx.assets.usePtfx('scr_rcbarry2'))
```

### Fx.assets.textureDict(dict, opts)

```lua
Fx.assets.textureDict(dict: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
```

- **Side:** client.
- **Returns:** the texture dictionary name (`RequestStreamedTextureDict(dict, false)`).
- **Fails with:** `AssetTimeout`.

```lua
local txd = Fx.yield(Fx.assets.textureDict('commonmenu'))
DrawSprite(txd, 'shop_box_tick', 0.5, 0.5, 0.02, 0.03, 0.0, 255, 255, 255, 255)
```

### Fx.assets.useTextureDict(dict, opts)

```lua
Fx.assets.useTextureDict(dict: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the texture dictionary name.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `SetStreamedTextureDictAsNoLongerNeeded` when the scope closes.

```lua
Fx.yield(Fx.assets.useTextureDict('mpinventory'))
```

### Fx.assets.scaleform(name, opts)

```lua
Fx.assets.scaleform(name: string, opts?: { timeout?: integer }) -> Fx.Effect<integer, AssetTimeout>
```

- **Side:** client.
- **Returns:** the scaleform handle from `RequestScaleformMovie` (not the name).
- **Fails with:** `AssetTimeout`.

```lua
local sf = Fx.yield(Fx.assets.scaleform('MP_BIG_MESSAGE_FREEMODE'))
BeginScaleformMovieMethod(sf, 'SHOW_SHARD_WASTED_MP_MESSAGE')
```

### Fx.assets.useScaleform(name, opts)

```lua
Fx.assets.useScaleform(name: string, opts?: { timeout?: integer }) -> Fx.Effect<integer, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the scaleform handle.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `SetScaleformMovieAsNoLongerNeeded(handle)` when the scope closes.

```lua
-- show a banner for 5 seconds; the draw loop stops and the movie is released when the scope closes
Fx.runFork(Fx.scoped(Fx.gen(function()
  local sf = Fx.yield(Fx.assets.useScaleform('MP_BIG_MESSAGE_FREEMODE'))
  BeginScaleformMovieMethod(sf, 'SHOW_SHARD_CENTERED_MP_MESSAGE')
  ScaleformMovieMethodAddParamTextureNameString('DELIVERED')
  EndScaleformMovieMethod()
  Fx.yield(Fx.tick.everyFrame(function() DrawScaleformMovieFullscreen(sf, 255, 255, 255, 255, 0) end):forkScoped())
  Fx.yield(Fx.sleep(5000))
end)))
```

### Fx.assets.audioBank(bank, opts)

```lua
Fx.assets.audioBank(bank: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
```

- **Side:** client.
- **Returns:** the bank name.
- **Fails with:** `AssetTimeout`.
- **Notes:** loading calls `RequestScriptAudioBank(bank, false)` every frame until it returns true.

```lua
Fx.yield(Fx.assets.audioBank('DLC_HEIST_HACKING_SNAKE'))
```

### Fx.assets.useAudioBank(bank, opts)

```lua
Fx.assets.useAudioBank(bank: string, opts?: { timeout?: integer }) -> Fx.Effect<string, AssetTimeout>
-- requires Scope
```

- **Side:** client.
- **Returns:** the bank name.
- **Fails with:** `AssetTimeout`.
- **Notes:** calls `ReleaseNamedScriptAudioBank` when the scope closes.

```lua
Fx.yield(Fx.assets.useAudioBank('DLC_HEIST_HACKING_SNAKE'))
```

### Fx.poll(check, timeout, onTimeout)

```lua
Fx.poll(check: fun(): boolean, timeout: integer, onTimeout: fun(): any) -> Fx.Effect<nil, any>
-- timeout: ms
-- onTimeout: builds the error
```

- **Side:** client (defined by the assets module).
- **Parameters:** `check`, called once per frame; `timeout`; `onTimeout`, returns the error to fail with.
- **Returns:** `nil` once `check()` returns true.
- **Fails with:** whatever `onTimeout()` returns.
- **Notes:** `Fx.poll` is created when `Fx.assets` loads. Before anything touches `Fx.assets`, `Fx.poll` is `nil` (the type file declares it unconditionally). Touch `Fx.assets` first, for example `local _ = Fx.assets`.

```lua
local DoorTimeout = Fx.TaggedError('DoorTimeout')
local _ = Fx.assets
local waitForDoor = Fx.poll(function() return DoesObjectOfTypeExistAtCoords(x, y, z, 1.0, doorHash, false) end,
  3000, function() return DoorTimeout { door = 'pacific_vault' } end)
```

## Entities

`Fx.entity` checks entities, waits for network ids and control, and spawns entities that are deleted when their scope closes.

Error classes: `EntityGone { entity }`, `ControlTimeout { entity, timeoutMs }`, `NetIdTimeout { netId, timeoutMs }`, `SpawnFailed { kind, model }` (`kind` is `vehicle`, `ped` or `object`). All on `Fx.entity`. The default timeout everywhere is `5000` ms.

### Fx.entity.exists(ent)

```lua
Fx.entity.exists(ent: integer) -> Fx.Effect<integer, EntityGone>
```

- **Side:** both.
- **Returns:** `ent` when it is not `nil`, not `0` and `DoesEntityExist(ent)`.
- **Fails with:** `EntityGone { entity = ent }`.

```lua
local veh = Fx.yield(Fx.entity.exists(GetVehiclePedIsIn(PlayerPedId(), false)))
```

### Fx.entity.delete(ent)

```lua
Fx.entity.delete(ent: integer) -> Fx.Effect<nil, never>
```

- **Side:** both.
- **Returns:** `nil`. Does nothing if the entity is already gone.
- **Fails with:** never.
- **Notes:** on the client it calls `SetEntityAsMissionEntity(ent, true, true)` before `DeleteEntity`. This is the release used by the scoped spawns.

```lua
Fx.yield(Fx.entity.delete(oldVehicle))
```

### Fx.entity.fromNetId(netId, opts)

```lua
Fx.entity.fromNetId(netId: integer, opts?: { timeout?: integer }) -> Fx.Effect<integer, NetIdTimeout>
```

- **Side:** both, with different checks.
- **Returns:** the entity handle.
- **Fails with:** `NetIdTimeout { netId, timeoutMs }` when it does not appear in time.
- **Notes:** server polls `NetworkGetEntityFromNetworkId` plus `DoesEntityExist`. Client polls `NetworkDoesNetworkIdExist`, then returns `NetToEnt(netId)`. Polled once per frame.

```lua
-- client: the server sent a net id for a vehicle that may not have streamed in yet
Fx.net.handle('garage:spawned', S.struct { netId = S.int }, function(input)
  return Fx.entity.fromNetId(input.netId, { timeout = 3000 }):flatMap(function(veh)
    return Fx.sync(function() SetPedIntoVehicle(PlayerPedId(), veh, -1) end)
  end)
end)
```

### Fx.entity.requestControl(ent, opts)

```lua
Fx.entity.requestControl(ent: integer, opts?: { timeout?: integer }) -> Fx.Effect<integer, EntityGone|ControlTimeout>
```

- **Side:** client only. On the server `Fx.entity.requestControl` is `nil` (the type file does not say so).
- **Returns:** `ent` once `NetworkHasControlOfEntity(ent)` is true.
- **Fails with:** `EntityGone` when the entity does not exist at the start; `ControlTimeout { entity, timeoutMs }`.
- **Notes:** calls `NetworkRequestControlOfEntity` every frame until it has control.

```lua
local veh = Fx.yield(Fx.entity.requestControl(target, { timeout = 2000 }))
SetVehicleDoorsLocked(veh, 2)
```

### Fx.entity.spawnVehicle(model, coords, heading, opts)

```lua
Fx.entity.spawnVehicle(model: string|integer, coords: { x: number, y: number, z: number }, heading?: number, opts?: { networked?: boolean, timeout?: integer }) -> Fx.Effect<integer, SpawnFailed|AssetNotFound|AssetTimeout>
-- coords: vector3 works
-- heading: default 0.0
-- requires Scope
```

- **Side:** both.
- **Parameters:** `opts.networked` defaults to `true`; `opts.timeout` (default `5000`) applies to the model load and, separately, to the wait for the entity to exist.
- **Returns:** the vehicle handle.
- **Fails with:** `SpawnFailed { kind = 'vehicle', model }` when the entity does not exist in time; on the client also `AssetNotFound` / `AssetTimeout` from loading the model.
- **Notes:**
  - Deleted with `Fx.entity.delete` when the current scope closes.
  - Client: loads the model with `Fx.assets.model`, calls `CreateVehicle(hash, x, y, z, heading, networked, true)`, then `SetModelAsNoLongerNeeded`.
  - Server: calls `CreateVehicle` directly with the same arguments; no model load.

```lua
-- client: a test drive that ends after 60 seconds, wherever it ends
Fx.runFork(Fx.scoped(Fx.gen(function()
  local veh = Fx.yield(Fx.entity.spawnVehicle('sultan', vector3(-56.8, -1109.1, 26.4), 70.0))
  SetPedIntoVehicle(PlayerPedId(), veh, -1)
  Fx.yield(Fx.sleep(60000))
end)))
```

### Fx.entity.spawnPed(model, coords, heading, opts)

```lua
Fx.entity.spawnPed(model: string|integer, coords: { x: number, y: number, z: number }, heading?: number, opts?: { networked?: boolean, timeout?: integer, pedType?: integer }) -> Fx.Effect<integer, SpawnFailed|AssetNotFound|AssetTimeout>
-- heading: default 0.0
-- requires Scope
```

- **Side:** both.
- **Parameters:** as `spawnVehicle`, plus `opts.pedType` (default `4`).
- **Returns:** the ped handle.
- **Fails with:** `SpawnFailed { kind = 'ped', model }`; on the client also `AssetNotFound` / `AssetTimeout`.
- **Notes:** calls `CreatePed(pedType, hash, x, y, z, heading, networked, true)`. Deleted when the scope closes.

```lua
Fx.yield(Fx.entity.spawnPed('s_m_y_cop_01', vector3(441.0, -982.0, 30.7), 90.0, { networked = false }))
```

### Fx.entity.spawnObject(model, coords, opts)

```lua
Fx.entity.spawnObject(model: string|integer, coords: { x: number, y: number, z: number }, opts?: { networked?: boolean, timeout?: integer }) -> Fx.Effect<integer, SpawnFailed|AssetNotFound|AssetTimeout>
-- requires Scope
```

- **Side:** both.
- **Parameters:** no heading; `opts` as `spawnVehicle`.
- **Returns:** the object handle.
- **Fails with:** `SpawnFailed { kind = 'object', model }`; on the client also `AssetNotFound` / `AssetTimeout`.
- **Notes:** calls `CreateObject(hash, x, y, z, networked, true, false)`. Deleted when the scope closes.

```lua
local cone = Fx.yield(Fx.entity.spawnObject('prop_roadcone02a', vector3(410.2, -1000.5, 28.3)))
PlaceObjectOnGroundProperly(cone)
```

## Frame loops

`Fx.tick` runs a function every frame on one plain Citizen thread, and stops when the fiber running the effect is interrupted or its scope closes. The effects never succeed; they run until stopped. If the function (or the condition) raises, the effect dies with that error as a defect. Run them with `Fx.runFork` and keep the fiber, or with `:forkScoped()` inside a scope. See [Concurrency](core-concurrency.md).

### Fx.tick.everyFrame(fn)

```lua
Fx.tick.everyFrame(fn: fun()) -> Fx.Effect<never, never>
```

- **Side:** both (on the server a frame is a server tick).
- **Parameters:** `fn`, called once per frame (`Wait(0)` between calls).
- **Returns:** never succeeds.
- **Fails with:** dies with the error `fn` raises.

```lua
local hud = Fx.runFork(Fx.tick.everyFrame(function()
  HideHudComponentThisFrame(14) -- crosshair
end))
-- later
hud:interruptAsFork(0)
```

### Fx.tick.whileNear(coords, radius, fn, opts)

```lua
Fx.tick.whileNear(coords: { x: number, y: number, z: number }, radius: number, fn: fun(distance: number), opts?: { checkMs?: integer }) -> Fx.Effect<never, never>
-- coords: vector3 works; read once
-- opts.checkMs: default 500
```

- **Side:** client (uses `PlayerPedId()`).
- **Parameters:** `fn` gets the distance from the local ped to `coords`; `opts.checkMs`, how often the distance is checked while out of range.
- **Returns:** never succeeds.
- **Fails with:** dies with the error `fn` raises.
- **Notes:** within `radius`, `fn` runs every frame. Outside it, the thread sleeps `checkMs` between distance checks, so being far away costs almost nothing.

```lua
local shop = vector3(25.7, -1347.3, 29.5)
Fx.runFork(Fx.tick.whileNear(shop, 10.0, function(d)
  DrawMarker(1, shop.x, shop.y, shop.z - 1.0, 0, 0, 0, 0, 0, 0, 1.5, 1.5, 0.5, 0, 150, 255, 120, false, false, 2, false, nil, nil, false)
  if d < 1.5 and IsControlJustPressed(0, 38) then TriggerEvent('shop:open') end
end))
```

### Fx.tick.whileTrue(condition, fn, opts)

```lua
Fx.tick.whileTrue(condition: fun(): boolean, fn: fun(), opts?: { checkMs?: integer }) -> Fx.Effect<never, never>
-- opts.checkMs: default 250
```

- **Side:** both.
- **Parameters:** `condition`, checked every frame while true and every `checkMs` while false; `fn`, run every frame while `condition()` is true.
- **Returns:** never succeeds.
- **Fails with:** dies with the error `condition` or `fn` raises.

```lua
-- client: show the speedometer only while driving
Fx.runFork(Fx.tick.whileTrue(function() return IsPedInAnyVehicle(PlayerPedId(), false) end, function()
  local kmh = GetEntitySpeed(GetVehiclePedIsIn(PlayerPedId(), false)) * 3.6
  Hud.drawSpeed(kmh)
end))
```
