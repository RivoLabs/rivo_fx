-- Typed RPC over net events, with timeouts, cancellation and tagged errors.
-- Wire format: docs/PROTOCOL.md.
--
-- Server:
--   Fx.rpc.register('bank:balance', { input = Fx.S.struct { account = Fx.S.string } },
--     function(src, input) return Bank.balance(src, input.account) end)
-- Client:
--   local balance = Fx.yield(Fx.rpc.call('bank:balance', { account = 'main' }, { timeout = 5000 }))
return function(Fx)
  local rpc = {}
  local isServer = Fx.isServer
  local RES = Fx.resourceName
  local S = Fx.S

  local function ev(res, kind) return ('__rfx:%s:%s'):format(res, kind) end

  rpc.RpcNotFound = Fx.TaggedError('RpcNotFound')
  rpc.RpcInvalidInput = Fx.TaggedError('RpcInvalidInput')
  rpc.RpcRateLimited = Fx.TaggedError('RpcRateLimited')
  rpc.RpcInternalError = Fx.TaggedError('RpcInternalError')
  rpc.RpcTimeout = Fx.TaggedError('RpcTimeout')
  rpc.RpcInvalidOutput = Fx.TaggedError('RpcInvalidOutput')

  local DEFAULT_TIMEOUT = 10000

  local Handled = Fx.metrics.histogram('rivo_fx_rpc_handler_ms', { help = 'RPC handler time by name and outcome' })
  local Calls = Fx.metrics.histogram('rivo_fx_rpc_call_ms', { help = 'RPC round trip seen by the caller, by name and outcome' })

  local function outcome(exit)
    if exit._tag == 'Success' then return 'ok' end
    if Fx.Cause.isInterruptedOnly(exit.cause) then return 'interrupted' end
    local e = Fx.Cause.failureOption(exit.cause)
    if #Fx.Cause.defects(exit.cause) == 0 and type(e) == 'table' and type(e._tag) == 'string' then
      -- the protocol's own tags and errors this resource declared; a tag a
      -- client made up (a callClient reply) would add label values without end
      if Fx._declaredTags[e._tag] then return e._tag end
      return 'error'
    end
    return 'defect'
  end

  local handlers = {}
  local running = {} -- caller key -> fiber
  local pending = {} -- id -> { resume, name, player }
  local nextId = 0

  local Request = S.struct {
    id = S.int,
    name = S.string:maxLen(128),
    from = S.string:maxLen(64),
    input = S.unknown,
    trace = S.unknown, -- W3C traceparent of the caller's span; anything else is ignored
  }
  local Cancel = S.struct { id = S.int, from = S.string:maxLen(64) }
  local Response = S.struct {
    id = S.int,
    ok = S.boolean,
    value = S.unknown,
    error = S.unknown,
  }

  ---Turn a handler failure into the wire error, or nil when nothing should be sent.
  local function wireError(name, cause)
    if Fx.Cause.isInterruptedOnly(cause) then return nil end
    local e = Fx.Cause.failureOption(cause)
    if e ~= nil and #Fx.Cause.defects(cause) == 0 and type(e) == 'table' and type(e._tag) == 'string' then
      return Fx.serializeError(e)
    end
    Fx.log.error(('rpc %q failed'):format(name), { cause = Fx.Cause.pretty(cause) })
    return { _tag = 'RpcInternalError', name = name }
  end

  -- Hosting ------------------------------------------------------------------

  ---Register an RPC handler on this side.
  ---spec.input: Schema for the input (required; Fx.S.unknown to opt out).
  ---spec.output: optional Schema checked before replying.
  ---spec.rateLimit: "10/s" default on the server, false to disable.
  ---spec.runtime: Fx.Runtime providing services.
  ---handler(src, input) on the server, handler(input) on the client; returns an effect or a value.
  function rpc.register(name, spec, handler)
    assert(type(name) == 'string', 'Fx.rpc.register: name must be a string')
    if type(spec) ~= 'table' or not Fx.net.isSchema(spec.input) then
      error(('Fx.rpc.register(%q): spec.input schema is required (use Fx.S.unknown to skip validation on purpose)'):format(name), 2)
    end
    local limiter
    if isServer and spec.rateLimit ~= false then limiter = Fx.RateLimiter.new(spec.rateLimit or '10/s') end
    handlers[name] = { spec = spec, handler = handler, limiter = limiter }
    rpc._listen()
    if spec.libCallback then Fx.compat.registerLibCallback(name, spec, handler, limiter) end
    return function() handlers[name] = nil end
  end

  local function respond(src, from, resp)
    if isServer then
      TriggerClientEvent(ev(from, 'res'), src, resp)
    else
      TriggerServerEvent(ev(from, 'res'), resp)
    end
  end

  local function onRequest(payload)
    local src = isServer and tonumber(source) or nil
    -- requests only come from clients; ignore server-local TriggerEvent calls
    if isServer and not src then return end
    local okReq, req = Request:validate(payload)
    if not okReq then
      if isServer then
        Fx.security.report({ kind = 'invalid_payload', source = src, name = ev(RES, 'req'), message = req })
      end
      return
    end
    local name, from, id = req.name, req.from, req.id
    local entry = handlers[name]
    if not entry then
      if isServer then Fx.security.report({ kind = 'unknown_rpc', source = src, name = name }) end
      return respond(src, from, { id = id, ok = false, error = { _tag = 'RpcNotFound', name = name } })
    end
    if entry.limiter and not entry.limiter:take(src) then
      Fx.security.report({ kind = 'rate_limited', source = src, name = name })
      return respond(src, from, { id = id, ok = false, error = { _tag = 'RpcRateLimited', name = name } })
    end
    local okIn, input = entry.spec.input:validate(req.input)
    if not okIn then
      if isServer then
        Fx.security.report({ kind = 'invalid_payload', source = src, name = name, message = input })
      end
      return respond(src, from, { id = id, ok = false, error = { _tag = 'RpcInvalidInput', name = name, message = input } })
    end

    local eff = Fx.suspend(function()
      local r
      if isServer then r = entry.handler(src, input) else r = entry.handler(input) end
      if Fx.isEffect(r) then return r end
      return Fx.succeed(r)
    end)
    if entry.spec.output then
      eff = eff:flatMap(function(v)
        local okOut, out = entry.spec.output:validate(v)
        if okOut then return Fx.succeed(out) end
        return Fx.die(('rpc %q returned invalid output: %s'):format(name, out))
      end)
    end
    local started = Fx._platform.current.now()
    local trace = type(req.trace) == 'string' and #req.trace <= 64 and req.trace or nil
    eff = eff:withSpan('rpc.server ' .. name, {
      kind = 'server', parent = trace,
      attributes = { ['rpc.name'] = name, ['rpc.caller'] = from, player = src },
    })

    local key = (src or 'server') .. ':' .. from .. ':' .. id
    if running[key] then return end
    local rt = entry.spec.runtime or Fx._runtime
    local opts = {
      onExit = function(exit)
        running[key] = nil
        Handled:observe(Fx._platform.current.now() - started, { name = name, outcome = outcome(exit) })
        if exit._tag == 'Success' then
          return respond(src, from, { id = id, ok = true, value = exit.value })
        end
        local err = wireError(name, exit.cause)
        if err then respond(src, from, { id = id, ok = false, error = err }) end
      end,
    }
    local fiber = rt and rt:runFork(eff, opts) or Fx.runFork(eff, opts)
    if not fiber.exit then
      running[key] = fiber
      if isServer and src and src > 0 then Fx.player.scope(src):unsafeAttachFiber(fiber) end
    end
  end

  local function onCancel(payload)
    local src = isServer and tonumber(source) or nil
    if isServer and not src then return end
    local ok, c = Cancel:validate(payload)
    if not ok then return end
    local key = (src or 'server') .. ':' .. c.from .. ':' .. c.id
    local fiber = running[key]
    if fiber then
      running[key] = nil
      fiber:interruptAsFork(0)
    end
  end

  -- Calling ------------------------------------------------------------------

  local function onResponse(payload)
    local src = isServer and tonumber(source) or nil
    if isServer and not src then return end
    local ok, resp = Response:validate(payload)
    if not ok then return end
    local p = pending[resp.id]
    if not p then return end
    -- On the server only the player we called may answer.
    if isServer and p.player ~= src then return end
    pending[resp.id] = nil
    if resp.ok then
      p.resume(Fx.succeed(resp.value))
    elseif type(resp.error) == 'table' and type(resp.error._tag) == 'string' then
      p.resume(Fx.fail(Fx.taggedFromTable(resp.error)))
    else
      p.resume(Fx.fail(rpc.RpcInternalError { name = p.name }))
    end
  end

  local listening = false
  function rpc._listen()
    if listening then return end
    listening = true
    RegisterNetEvent(ev(RES, 'req'), onRequest)
    RegisterNetEvent(ev(RES, 'cancel'), onCancel)
    RegisterNetEvent(ev(RES, 'res'), onResponse)
  end

  local function call(name, input, opts, player)
    opts = opts or {}
    local target = opts.resource or RES
    local timeout = opts.timeout or DEFAULT_TIMEOUT
    rpc._listen()
    -- tp: the caller's span as a traceparent, so the host's span joins its trace
    local function request(tp)
      local eff = Fx.async(function(resume)
        nextId = nextId + 1
        local id = nextId
        pending[id] = { resume = resume, name = name, player = player }
        local req = { id = id, name = name, from = RES, input = input, trace = tp }
        if player then
          TriggerClientEvent(ev(target, 'req'), player, req)
        else
          TriggerServerEvent(ev(target, 'req'), req)
        end
        return function()
          if pending[id] then
            pending[id] = nil
            local c = { id = id, from = RES }
            if player then TriggerClientEvent(ev(target, 'cancel'), player, c)
            else TriggerServerEvent(ev(target, 'cancel'), c) end
          end
        end
      end):timeoutFail(timeout, function() return rpc.RpcTimeout { name = name, timeoutMs = timeout } end)
      if opts.output then
        eff = eff:flatMap(function(v)
          local ok, out = opts.output:validate(v)
          if ok then return Fx.succeed(out) end
          return Fx.fail(rpc.RpcInvalidOutput { name = name, message = out })
        end)
      end
      return eff
    end
    local traced = Fx.withFiber(function(fiber) return request(Fx.trace.traceparentOf(fiber)) end)
      :withSpan('rpc.client ' .. name, {
        kind = 'client', attributes = { ['rpc.name'] = name, ['rpc.target'] = target, player = player },
      })
    return Fx.suspend(function()
      local started = Fx._platform.current.now()
      return Fx._onExitSync(traced, function(exit)
        Calls:observe(Fx._platform.current.now() - started, { name = name, outcome = outcome(exit) })
      end)
    end)
  end

  if isServer then
    ---Call an RPC registered on a client. The response is accepted only from that player.
    ---opts: { timeout = ms (default 10000), resource = target resource, output = Schema }
    function rpc.callClient(player, name, input, opts)
      return call(name, input, opts, tonumber(player))
    end
  else
    ---Call an RPC registered on the server.
    ---opts: { timeout = ms (default 10000), resource = target resource, output = Schema }
    ---@return Fx.Effect<any, table>
    function rpc.call(name, input, opts)
      return call(name, input, opts, nil)
    end
  end

  return rpc
end
