-- Entities: existence checks, network control, net ids, and scoped spawns
-- that are deleted when their scope closes.
return function(Fx)
  local entity = {}
  local isServer = Fx.isServer

  entity.EntityGone = Fx.TaggedError('EntityGone')
  entity.ControlTimeout = Fx.TaggedError('ControlTimeout')
  entity.NetIdTimeout = Fx.TaggedError('NetIdTimeout')
  entity.SpawnFailed = Fx.TaggedError('SpawnFailed')

  local DEFAULT_TIMEOUT = 5000

  ---Succeeds with the entity if it exists, else fails with EntityGone.
  function entity.exists(ent)
    return Fx.suspend(function()
      if ent and ent ~= 0 and DoesEntityExist(ent) then return Fx.succeed(ent) end
      return Fx.fail(entity.EntityGone { entity = ent })
    end)
  end

  ---Delete the entity if it still exists.
  function entity.delete(ent)
    return Fx.sync(function()
      if ent and ent ~= 0 and DoesEntityExist(ent) then
        if not isServer then SetEntityAsMissionEntity(ent, true, true) end
        DeleteEntity(ent)
      end
    end)
  end

  local function poll(check, timeout, onTimeout)
    local loop
    loop = function()
      return Fx.suspend(function()
        if check() then return Fx.unit end
        return Fx.sleep(0):zipRight(loop())
      end)
    end
    return loop():timeoutFail(timeout, onTimeout)
  end

  if isServer then
    ---The entity for a network id. Fails with NetIdTimeout if it never appears.
    function entity.fromNetId(netId, opts)
      local timeout = opts and opts.timeout or DEFAULT_TIMEOUT
      local ent
      return poll(function()
        ent = NetworkGetEntityFromNetworkId(netId)
        return ent and ent ~= 0 and DoesEntityExist(ent)
      end, timeout, function() return entity.NetIdTimeout { netId = netId, timeoutMs = timeout } end)
        :map(function() return ent end)
    end
  else
    ---The entity for a network id. Fails with NetIdTimeout if it never appears.
    function entity.fromNetId(netId, opts)
      local timeout = opts and opts.timeout or DEFAULT_TIMEOUT
      return poll(function() return NetworkDoesNetworkIdExist(netId) end, timeout,
        function() return entity.NetIdTimeout { netId = netId, timeoutMs = timeout } end)
        :map(function() return NetToEnt(netId) end)
    end

    ---Request network control. Fails with ControlTimeout or EntityGone.
    function entity.requestControl(ent, opts)
      local timeout = opts and opts.timeout or DEFAULT_TIMEOUT
      return entity.exists(ent):zipRight(poll(function()
        if NetworkHasControlOfEntity(ent) then return true end
        NetworkRequestControlOfEntity(ent)
        return false
      end, timeout, function() return entity.ControlTimeout { entity = ent, timeoutMs = timeout } end)):as(ent)
    end
  end

  local function hashOf(m) if type(m) == 'string' then return joaat(m) end return m end

  ---Spawn and delete the entity when the current Scope closes.
  ---create(hash) returns the entity handle.
  local function spawnScoped(kind, model, create, opts)
    local hash = hashOf(model)
    local timeout = opts and opts.timeout or DEFAULT_TIMEOUT
    local prepare = Fx.unit
    if not isServer then prepare = Fx.assets.model(hash, { timeout = timeout }) end
    return prepare:zipRight(Fx.acquireRelease(Fx.sync(function()
      local ent = create(hash)
      if not isServer then SetModelAsNoLongerNeeded(hash) end
      return ent
    end), function(ent) return entity.delete(ent) end)):flatMap(function(ent)
      local found = false
      return poll(function()
        found = ent and ent ~= 0 and DoesEntityExist(ent)
        return found
      end, timeout, function() return entity.SpawnFailed { kind = kind, model = model } end):as(ent)
    end)
  end

  ---Spawn a vehicle that is deleted when the current Scope closes.
  ---opts: { networked = true, timeout = ms }
  function entity.spawnVehicle(model, coords, heading, opts)
    local net = not (opts and opts.networked == false)
    return spawnScoped('vehicle', model, function(hash)
      return CreateVehicle(hash, coords.x, coords.y, coords.z, heading or 0.0, net, true)
    end, opts)
  end

  ---Spawn a ped that is deleted when the current Scope closes.
  function entity.spawnPed(model, coords, heading, opts)
    local net = not (opts and opts.networked == false)
    local pedType = opts and opts.pedType or 4
    return spawnScoped('ped', model, function(hash)
      return CreatePed(pedType, hash, coords.x, coords.y, coords.z, heading or 0.0, net, true)
    end, opts)
  end

  ---Spawn an object that is deleted when the current Scope closes.
  function entity.spawnObject(model, coords, opts)
    local net = not (opts and opts.networked == false)
    return spawnScoped('object', model, function(hash)
      return CreateObject(hash, coords.x, coords.y, coords.z, net, true, false)
    end, opts)
  end

  return entity
end
