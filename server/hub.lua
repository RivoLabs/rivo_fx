-- The rivo_fx resource's own server script: serves the metrics and recent
-- spans of every resource that uses Rivo FX over the server's HTTP port.
--
--   GET http://<server>:30120/rivo_fx/metrics   Prometheus text format
--   GET http://<server>:30120/rivo_fx/spans     recent spans as JSON
--
-- Off until the server convar rivo_fx:metricsToken is set; requests then need
-- the header "Authorization: Bearer <token>". Set it with `set` (not `setr`),
-- so it never reaches clients.
local C = RivoFxCollect -- shared/collect.lua

local function sameString(a, b)
  if #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = diff | (a:byte(i) ~ b:byte(i)) end
  return diff == 0
end

local function header(headers, name)
  for k, v in pairs(headers or {}) do
    if type(k) == 'string' and k:lower() == name then return v end
  end
  return nil
end

---Answer a request: returns status, headers, body. Plain function so it can
---be tested without an HTTP server.
local function handle(method, path, headers)
  local token = GetConvar('rivo_fx:metricsToken', '')
  if token == '' then
    return 404, { ['Content-Type'] = 'text/plain' }, 'rivo_fx telemetry is off (set rivo_fx:metricsToken)\n'
  end
  local auth = header(headers, 'authorization')
  if type(auth) ~= 'string' or not sameString(auth, 'Bearer ' .. token) then
    return 401, { ['Content-Type'] = 'text/plain', ['WWW-Authenticate'] = 'Bearer' }, 'unauthorized\n'
  end
  if method ~= 'GET' then return 405, { ['Content-Type'] = 'text/plain' }, 'GET only\n' end
  local route, query = path:match('^([^?]*)%??(.*)$')
  if route == '/metrics' then
    return 200, { ['Content-Type'] = 'text/plain; version=0.0.4' }, Fx.metrics.prometheus(nil, C.mergedMetrics())
  elseif route == '/spans' then
    local limit = tonumber(query:match('limit=(%d+)')) or 100
    return 200, { ['Content-Type'] = 'application/json' }, json.encode(C.recentSpans(math.min(limit, 1000)))
  end
  return 404, { ['Content-Type'] = 'text/plain' }, 'not found\n'
end

RivoFxHub = { handle = handle, resources = C.resources, mergedMetrics = C.mergedMetrics }

SetHttpHandler(function(req, res)
  local ok, status, hdrs, body = pcall(handle, req.method, req.path or '/', req.headers)
  if not ok then
    Fx.log.error('rivo_fx telemetry request failed', { error = tostring(status) })
    status, hdrs, body = 500, { ['Content-Type'] = 'text/plain' }, 'internal error\n'
  end
  res.writeHead(status, hdrs)
  res.send(body)
end)
