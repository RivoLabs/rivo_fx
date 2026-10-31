-- Rivo FX entry point.
--
-- Consumers load it into their own Lua runtime (like ox_lib):
--   lua54 'yes'
--   dependency 'rivo_fx'
--   shared_script '@rivo_fx/init.lua'
--
-- Core modules load eagerly; FiveM modules (Fx.net, Fx.rpc, Fx.assets, ...)
-- load on first use.
if rawget(_G, 'Fx') and rawget(_G, 'Fx')._rivo then return Fx end

local RESOURCE = 'rivo_fx'

local function readFile(path)
  if LoadResourceFile then
    return LoadResourceFile(RESOURCE, path)
  end
  local root = rawget(_G, 'RIVO_FX_ROOT') or './'
  local f = io.open(root .. path, 'r')
  if not f then return nil end
  local src = f:read('a')
  f:close()
  return src
end

local function loadModule(path)
  local src = readFile(path)
  if not src then error(('rivo_fx: cannot load %s (is rivo_fx started and up to date?)'):format(path), 3) end
  local chunk, err = load(src, '@@rivo_fx/' .. path, 't')
  if not chunk then error(err, 3) end
  return chunk()
end

---@class Fx
local Fx = { _rivo = true, version = '1.0.0' }
Fx._loadModule = loadModule

for _, name in ipairs({ 'platform', 'effect', 'data', 'schedule', 'concurrency', 'layer', 'schema', 'stream', 'trace', 'metrics' }) do
  loadModule('lib/core/' .. name .. '.lua')(Fx)
end

local isServer = IsDuplicityVersion and IsDuplicityVersion() or false
Fx.isServer = isServer
Fx.resourceName = GetCurrentResourceName and GetCurrentResourceName() or 'test'

local lazy = {
  log = 'lib/fivem/log.lua',
  security = 'lib/fivem/security.lua',
  RateLimiter = 'lib/fivem/ratelimit.lua',
  net = 'lib/fivem/net.lua',
  rpc = 'lib/fivem/rpc.lua',
  compat = 'lib/fivem/compat.lua',
  player = 'lib/fivem/player.lua',
  config = 'lib/fivem/config.lua',
  assets = 'lib/fivem/assets.lua',
  entity = 'lib/fivem/entity.lua',
  kvp = 'lib/fivem/kvp.lua',
  state = 'lib/fivem/state.lua',
  tick = 'lib/fivem/tick.lua',
  db = 'lib/fivem/db.lua',
  framework = 'lib/fivem/framework.lua',
  nui = 'lib/fivem/nui.lua',
}

-- Names a lazy module defines on Fx itself (Fx.logInfo comes with Fx.log).
local lazyAlias = { logDebug = 'log', logInfo = 'log', logWarn = 'log', logError = 'log' }

setmetatable(Fx, {
  __index = function(t, key)
    local owner = lazyAlias[key]
    if owner then
      local _ = t[owner] -- loads the module, which sets the field
      return rawget(t, key)
    end
    local path = lazy[key]
    if not path then return nil end
    local value = loadModule(path)(Fx)
    rawset(t, key, value)
    return value
  end,
})

-- The resource scope: closes when this resource stops.
Fx.resourceScope = Fx.Scope.unsafeMake()

---Run fn (or an effect) when this resource stops.
function Fx.onStop(fin)
  Fx.resourceScope:unsafeAddFinalizer(function()
    if Fx.isEffect(fin) then return fin end
    return Fx.sync(fin)
  end)
end

if AddEventHandler then
  AddEventHandler('onResourceStop', function(resource)
    if resource ~= Fx.resourceName then return end
    Fx._interruptRoots()
    Fx._closeAllScopes(Fx.Exit.failCause(Fx.Cause.interrupt(0)))
  end)
end

loadModule('lib/fivem/telemetry.lua')(Fx)

_G.Fx = Fx
return Fx
