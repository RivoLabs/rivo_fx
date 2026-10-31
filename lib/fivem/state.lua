-- Schema-typed state bag keys.
--   local Job = Fx.state.key('job', S.struct { name = S.string, grade = S.int })
--   Fx.yield(Job:set(Fx.state.player(src), { name = 'police', grade = 2 }))
--   Job:onChange(function(change) print(change.player, change.value.name) end)
-- Values that fail the schema never reach a handler. On the server, an invalid
-- value a client wrote to its own player or entity bag is reported as an
-- `invalid_state` security event.
return function(Fx)
  local state = {}

  state.StateInvalid = Fx.TaggedError('StateInvalid')
  state.StateTimeout = Fx.TaggedError('StateTimeout')

  -- Bags ---------------------------------------------------------------------

  local function bag(name, raw) return { name = name, state = raw } end

  ---GlobalState.
  function state.global() return bag('global', GlobalState) end

  ---A player's bag. On the client, omit src for the local player.
  ---@param src? integer server id
  function state.player(src)
    if not Fx.isServer and src == nil then
      return bag('player:' .. GetPlayerServerId(PlayerId()), LocalPlayer.state)
    end
    return bag('player:' .. src, Player(src).state)
  end

  ---An entity's bag.
  ---@param ent integer
  function state.entity(ent)
    local name
    if Fx.isServer or NetworkGetEntityIsNetworked(ent) then
      name = 'entity:' .. NetworkGetNetworkIdFromEntity(ent)
    else
      name = 'localEntity:' .. ent
    end
    return bag(name, Entity(ent).state)
  end

  -- Keys -----------------------------------------------------------------------

  local Key = {}
  Key.__index = Key

  local function check(self, value)
    if value == nil then return true, nil end
    return self.schema:validate(value)
  end

  ---The current value (nil when unset). Fails with StateInvalid when the bag
  ---holds a value that does not match the schema.
  function Key:get(b)
    local key = self
    return Fx.suspend(function()
      local ok, v = check(key, b.state[key.name])
      if ok then return Fx.succeed(v) end
      return Fx.fail(state.StateInvalid { key = key.name, bag = b.name, message = v })
    end)
  end

  ---Set the value after checking it. opts.replicated defaults to true on the
  ---server and false on the client (a client may only replicate to bags it
  ---owns: its own player, entities it controls).
  function Key:set(b, value, opts)
    local key = self
    return Fx.suspend(function()
      local ok, v = check(key, value)
      if not ok then
        return Fx.fail(state.StateInvalid { key = key.name, bag = b.name, message = v })
      end
      local replicated = Fx.isServer
      if opts and opts.replicated ~= nil then replicated = opts.replicated end
      b.state:set(key.name, v, replicated)
      return Fx.unit
    end)
  end

  ---Remove the value.
  function Key:clear(b, opts) return self:set(b, nil, opts) end

  local function describe(bagName)
    local change = { bag = bagName }
    if bagName:sub(1, 7) == 'player:' then
      local p = GetPlayerFromStateBagName(bagName)
      if p and p ~= 0 then change.player = p end
    elseif bagName:sub(1, 7) == 'entity:' or bagName:sub(1, 12) == 'localEntity:' then
      local e = GetEntityFromStateBagName(bagName)
      if e and e ~= 0 then change.entity = e end
    end
    return change
  end

  local function reportInvalid(key, change, message)
    local source = change.player
    if not source and change.entity and Fx.isServer then
      source = NetworkGetEntityOwner(change.entity)
    end
    Fx.security.report({
      kind = 'invalid_state', source = source, name = key.name, message = message, bag = change.bag,
    })
  end

  ---Call handler(change) for every valid change of this key, where change is
  ---{ bag, value, replicated, player?, entity? }. handler may return an
  ---effect, which is run on its own fiber. opts.bag narrows it to one bag
  ---(a bag from Fx.state.player/entity/global, or a bag name). Returns the
  ---cookie for RemoveStateBagChangeHandler; handlers also end with the resource.
  function Key:onChange(handler, opts)
    local key = self
    local filter = opts and opts.bag
    if type(filter) == 'table' then filter = filter.name end
    return AddStateBagChangeHandler(key.name, filter, function(bagName, _, value, _, replicated)
      local change = describe(bagName)
      change.replicated = replicated
      local ok, v = check(key, value)
      if not ok then
        -- on the server, replicated means a client wrote it
        if Fx.isServer and replicated then reportInvalid(key, change, v) end
        return
      end
      change.value = v
      local okCall, res = pcall(handler, change)
      if not okCall then
        Fx._reportDefect(('state handler %s'):format(key.name), res)
      elseif Fx.isEffect(res) then
        Fx.runFork(res)
      end
    end)
  end

  ---Scoped onChange: the handler is removed when the scope closes.
  function Key:watch(handler, opts)
    local key = self
    return Fx.acquireRelease(
      Fx.sync(function() return key:onChange(handler, opts) end),
      function(cookie) return Fx.sync(function() RemoveStateBagChangeHandler(cookie) end) end
    ):asVoid()
  end

  ---Valid changes of this key as a stream of change records (see onChange;
  ---opts.bag narrows it to one bag). opts.buffer and opts.strategy as in
  ---Fx.Stream.async. The handler is registered while the stream runs.
  function Key:changes(opts)
    local key = self
    return Fx.Stream.async(function(push)
      local cookie = key:onChange(push, opts)
      return function() RemoveStateBagChangeHandler(cookie) end
    end, opts)
  end

  ---Wait until the bag's value satisfies predicate (default: not nil) and
  ---succeed with it. opts.timeout fails with StateTimeout.
  function Key:await(b, predicate, opts)
    local key = self
    predicate = predicate or function(v) return v ~= nil end
    local eff = Fx.async(function(resume)
      local ok, current = check(key, b.state[key.name])
      if ok and predicate(current) then resume(Fx.succeed(current)) return end
      local cookie
      cookie = key:onChange(function(change)
        if predicate(change.value) then
          RemoveStateBagChangeHandler(cookie)
          resume(Fx.succeed(change.value))
        end
      end, { bag = b })
      return function() RemoveStateBagChangeHandler(cookie) end
    end)
    if opts and opts.timeout then
      eff = eff:timeoutFail(opts.timeout, function()
        return state.StateTimeout { key = key.name, bag = b.name, timeoutMs = opts.timeout }
      end)
    end
    return eff
  end

  ---Define a typed key.
  ---@param name string
  ---@param schema Fx.Schema
  function state.key(name, schema)
    return setmetatable({ name = name, schema = schema }, Key)
  end

  return state
end
