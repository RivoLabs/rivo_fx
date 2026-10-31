-- /fxdev, server side: answers the devtools on a player's client with one
-- view (overview, fibers, spans, failures, metrics) of every resource on the
-- server that uses Rivo FX. Only for players with the ACE rivo_fx.devtools:
--   add_ace group.admin rivo_fx.devtools allow
-- Spans and failures can hold player ids and error details, so keep it to
-- people who could read the server console anyway.
local C = RivoFxCollect -- shared/collect.lua
local S = Fx.S

local Pull = S.struct {
  seq = S.int,
  view = S.enum { 'overview', 'fibers', 'spans', 'failures', 'metrics' },
  fresh = S.boolean:optional(), -- the devtools just opened: send all spans and failures again
}

local limiter = Fx.RateLimiter.new('10/s')
local cursors = {} -- player -> what they were sent already (shared/collect.lua C.view)

RegisterNetEvent('rivo_fx:devtools:pull', function(payload)
  local src = tonumber(source)
  if not src or src <= 0 then return end
  if not limiter:take(src) then
    Fx.security.report({ kind = 'rate_limited', source = src, name = 'rivo_fx:devtools:pull' })
    return
  end
  local ok, req = Pull:validate(payload)
  if not ok then
    Fx.security.report({ kind = 'invalid_payload', source = src, name = 'rivo_fx:devtools:pull', message = tostring(req) })
    return
  end
  if not IsPlayerAceAllowed(src, 'rivo_fx.devtools') then
    TriggerClientEvent('rivo_fx:devtools:data', src, { seq = req.seq, denied = true })
    return
  end
  if req.fresh or not cursors[src] then cursors[src] = {} end
  local started = GetGameTimer()
  local data = C.view(req.view, cursors[src])
  -- latent: a metrics or spans view can be tens of KB
  TriggerLatentClientEvent('rivo_fx:devtools:data', src, 500000, {
    seq = req.seq, view = req.view, side = 'server', data = data, now = Fx.trace.nowMs(),
    cost = GetGameTimer() - started, -- ms spent collecting: the client polls less when it is high
  })
end)

AddEventHandler('playerDropped', function()
  cursors[tonumber(source)] = nil
end)
