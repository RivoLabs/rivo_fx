-- Validated, rate-limited net events.
--
-- Server:
--   Fx.net.handle('bank:deposit', Deposit, function(src, input)
--     return Fx.gen(function() ... end)
--   end, { rateLimit = '5/s' })
-- Client:
--   Fx.net.handle('hud:update', Hud, function(input) ... end)
--
-- Each event carries exactly one argument: the payload (docs/PROTOCOL.md).
return function(Fx)
  local net = {}
  local isServer = Fx.isServer
  local Delivered = Fx.metrics.counter('rivo_fx_net_events_total', { help = 'Net events that passed their checks, by name' })

  local function isSchema(v) return type(v) == 'table' and getmetatable(v) == Fx.S._mt end
  net.isSchema = isSchema

  ---Run a handler's result (an effect, or nothing) and log failures.
  function net._run(result, what, opts)
    if not Fx.isEffect(result) then return nil end
    local rt = opts and opts.runtime or Fx._runtime
    local fiberOpts = {
      onExit = function(exit)
        if exit._tag == 'Failure' and not Fx.Cause.isInterruptedOnly(exit.cause) then
          Fx.log.error(what .. ' failed', { cause = Fx.Cause.pretty(exit.cause) })
        end
      end,
    }
    if rt then return rt:runFork(result, fiberOpts) end
    return Fx.runFork(result, fiberOpts)
  end

  ---Register a net event handler. A schema is required; pass Fx.S.unknown
  ---to accept anything on purpose.
  ---Server handler: fun(src, input): Fx.Effect|nil. Client handler: fun(input).
  ---opts.rateLimit: "10/s" (default, server only) or false.
  ---opts.runtime: Fx.Runtime that provides services (default Fx.setRuntime's).
  ---opts.playerScoped: interrupt the handler fiber if the player drops (default true).
  ---Returns a function that removes the handler.
  ---@param name string
  ---@param schema Fx.Schema
  ---@param handler function
  ---@param opts? { rateLimit?: string|false, runtime?: Fx.Runtime, playerScoped?: boolean }
  function net.handle(name, schema, handler, opts)
    assert(type(name) == 'string', 'Fx.net.handle: name must be a string')
    if not isSchema(schema) then
      error(('Fx.net.handle(%q): a schema is required (use Fx.S.unknown to skip validation on purpose)'):format(name), 2)
    end
    assert(type(handler) == 'function', 'Fx.net.handle: handler must be a function')
    opts = opts or {}
    local what = ('net event %q'):format(name)

    local spanName = 'net ' .. name
    return net._listen(name, schema, opts, function(src, input)
      if isServer then
        local okCall, result = pcall(handler, src, input)
        if not okCall then
          Fx.log.error(what .. ' handler raised', { error = tostring(result) })
          return
        end
        if Fx.isEffect(result) then
          result = result:withSpan(spanName, { kind = 'server', attributes = { ['net.event'] = name, player = src } })
        end
        local fiber = net._run(result, what, opts)
        if fiber and opts.playerScoped ~= false then
          Fx.player.scope(src):unsafeAttachFiber(fiber)
        end
      else
        local okCall, result = pcall(handler, input)
        if not okCall then
          Fx.log.error(what .. ' handler raised', { error = tostring(result) })
          return
        end
        if Fx.isEffect(result) then
          result = result:withSpan(spanName, { kind = 'server', attributes = { ['net.event'] = name } })
        end
        net._run(result, what, opts)
      end
    end)
  end

  -- Register the event with the checks every net event gets (player source,
  -- rate limit, schema) and call deliver(src, input) for what passes. src is
  -- nil on the client. Returns a function that removes the handler.
  function net._listen(name, schema, opts, deliver)
    local limiter
    if isServer and opts.rateLimit ~= false then
      limiter = Fx.RateLimiter.new(opts.rateLimit or '10/s')
    end
    local what = ('net event %q'):format(name)

    local h = RegisterNetEvent(name, function(payload)
      if isServer then
        -- Only players send net events; a server-local TriggerEvent has no player source.
        local src = tonumber(source)
        if not src or src <= 0 then return end
        if limiter and not limiter:take(src) then
          Fx.security.report({ kind = 'rate_limited', source = src, name = name })
          return
        end
        local ok, input = schema:validate(payload)
        if not ok then
          Fx.security.report({ kind = 'invalid_payload', source = src, name = name, message = input })
          return
        end
        Delivered:inc(1, { name = name })
        deliver(src, input)
      else
        local ok, input = schema:validate(payload)
        if not ok then
          Fx.log.warn(what .. ' payload from server failed validation', { message = input })
          return
        end
        Delivered:inc(1, { name = name })
        deliver(nil, input)
      end
    end)
    return function() RemoveEventHandler(h) end
  end

  ---A net event as a stream, with the same checks as net.handle (schema,
  ---and on the server a player source and a rate limit). On the server each
  ---value is { source = src, input = input }; on the client it is the input.
  ---The handler is registered while the stream runs. opts.rateLimit as in
  ---net.handle; opts.buffer and opts.strategy as in Fx.Stream.async.
  ---@param name string
  ---@param schema Fx.Schema
  ---@param opts? { rateLimit?: string|false, buffer?: integer, strategy?: 'sliding'|'dropping' }
  function net.stream(name, schema, opts)
    assert(type(name) == 'string', 'Fx.net.stream: name must be a string')
    if not isSchema(schema) then
      error(('Fx.net.stream(%q): a schema is required (use Fx.S.unknown to skip validation on purpose)'):format(name), 2)
    end
    opts = opts or {}
    return Fx.Stream.async(function(push)
      return net._listen(name, schema, opts, function(src, input)
        if isServer then push({ source = src, input = input }) else push(input) end
      end)
    end, opts)
  end

  if isServer then
    ---Send to one player (or -1 for everyone).
    function net.send(name, target, payload) TriggerClientEvent(name, target, payload) end
    function net.broadcast(name, payload) TriggerClientEvent(name, -1, payload) end
    ---Effect version of send.
    function net.emit(name, target, payload)
      return Fx.sync(function() TriggerClientEvent(name, target, payload) end)
    end
  else
    function net.send(name, payload) TriggerServerEvent(name, payload) end
    ---Effect version of send.
    function net.emit(name, payload)
      return Fx.sync(function() TriggerServerEvent(name, payload) end)
    end
  end

  return net
end
