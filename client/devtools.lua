-- /fxdev: the Rivo FX devtools. Live fibers, traces, failures and metrics of
-- every resource using Rivo FX, on the server and on this client. The server
-- decides who may open it (server/devtools.lua, ACE rivo_fx.devtools).
local C = RivoFxCollect -- shared/collect.lua
local S = Fx.S

local VIEWS = { 'overview', 'fibers', 'spans', 'failures', 'metrics' }
local POLL_MS = 1000
local MAX_POLL_MS = 5000
local REPLY_TIMEOUT_MS = 5000
-- Collecting from hundreds of resources costs server and client frame time,
-- so the wait between polls grows with it: at most ~2.5% of the time.
local COST_FACTOR = 40

local isOpen, opening, paused = false, false, false
local view = 'overview'
local seq, waiting, waitingSince = 0, nil, 0
local cursors = {} -- what the page already has from this client
local poller
local cost = { server = 0, client = 0 }

local function pollDelay()
  return math.min(MAX_POLL_MS, math.max(POLL_MS, math.max(cost.server, cost.client) * COST_FACTOR))
end

local function post(msg) SendNUIMessage(msg) end

local function pullServer(fresh)
  if waiting and GetGameTimer() - waitingSince < REPLY_TIMEOUT_MS then return end
  seq = seq + 1
  waiting, waitingSince = seq, GetGameTimer()
  TriggerServerEvent('rivo_fx:devtools:pull', { seq = seq, view = view, fresh = fresh or nil })
end

local function pullClient()
  local started = GetGameTimer()
  local data = C.view(view, cursors)
  cost.client = GetGameTimer() - started
  post({ type = 'data', side = 'client', view = view, data = data, now = Fx.trace.nowMs(), poll = pollDelay() })
end

local function refresh()
  pullServer()
  pullClient()
end

local function close()
  if not isOpen then return end
  isOpen = false
  if poller then poller:interruptAsFork(0) end
  poller = nil
  SetNuiFocus(false, false)
  post({ type = 'close' })
end

local function show()
  isOpen, opening = true, false
  cursors = {}
  SetNuiFocus(true, true)
  post({ type = 'open', view = view, paused = paused })
  pullClient()
  poller = Fx.runFork(Fx.gen(function()
    while true do
      Fx.yield(Fx.sleep(pollDelay()))
      if not paused then refresh() end
    end
  end))
end

local function notify(text)
  print('^3[rivo_fx]^7 ' .. text)
  TriggerEvent('chat:addMessage', { args = { '^3rivo_fx', text } })
end

RegisterNetEvent('rivo_fx:devtools:data', function(msg)
  if type(msg) ~= 'table' then return end
  if msg.seq == waiting then waiting = nil end
  if msg.denied then
    if opening then
      opening = false
      notify('/fxdev needs the rivo_fx.devtools permission (add_ace group.admin rivo_fx.devtools allow)')
    end
    close()
    return
  end
  if opening then show() end
  if type(msg.cost) == 'number' then cost.server = msg.cost end
  if isOpen then post({ type = 'data', side = 'server', view = msg.view, data = msg.data, now = msg.now, poll = pollDelay() }) end
end)

local ALIASES = { traces = 'spans', trace = 'spans', fiber = 'fibers', failure = 'failures', metric = 'metrics' }

-- /fxdev toggles; /fxdev <view> opens on (or switches to) a view.
RegisterCommand('fxdev', function(_, args)
  local wanted = args[1] and args[1]:lower()
  wanted = wanted and (ALIASES[wanted] or wanted)
  local valid = false
  for _, v in ipairs(VIEWS) do if v == wanted then valid = true end end
  if valid then view = wanted end
  if isOpen then
    if not valid then return close() end
    post({ type = 'view', view = view })
    waiting = nil
    return refresh()
  end
  -- open once the server says this player may
  opening = true
  waiting = nil
  pullServer(true)
end, false)
TriggerEvent('chat:addSuggestion', '/fxdev', 'Rivo FX devtools: fibers, traces, failures, metrics', {
  { name = 'view', help = 'overview, fibers, traces, failures or metrics (optional)' },
})

-- For tests on a real client: TriggerEvent('rivo_fx:devtools:probe') makes the
-- page answer with what it shows, as the local event 'rivo_fx:devtools:probed'
-- { open, view, rows, text, errors }.
AddEventHandler('rivo_fx:devtools:probe', function() post({ type = 'probe' }) end)
Fx.nui.handle('probe', { input = S.unknown }, function(input)
  TriggerEvent('rivo_fx:devtools:probed', input)
end)

Fx.nui.handle('close', { input = S.struct {} }, function() close() end)

Fx.nui.handle('view', { input = S.struct { view = S.enum(VIEWS) } }, function(input)
  if input.view ~= view then
    view = input.view
    waiting = nil
    if isOpen then refresh() end
  end
end)

Fx.nui.handle('pause', { input = S.struct { paused = S.boolean } }, function(input)
  paused = input.paused
end)

Fx.nui.handle('refresh', { input = S.struct {} }, function()
  if isOpen then
    waiting = nil
    refresh()
  end
end)

AddEventHandler('onResourceStop', function(res)
  if res == GetCurrentResourceName() and isOpen then SetNuiFocus(false, false) end
end)
