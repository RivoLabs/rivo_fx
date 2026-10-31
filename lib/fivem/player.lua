-- Server: per-player scopes. Everything tied to a player's scope is released
-- (and fibers interrupted) when the player drops.
return function(Fx)
  local player = {}
  local scopes = {}

  ---The player's scope (created on first use, closed on playerDropped).
  function player.scope(src)
    src = tonumber(src)
    local s = scopes[src]
    if not s or s.closed then
      s = Fx.Scope.unsafeMake()
      scopes[src] = s
    end
    return s
  end

  ---Run eff in the player's scope as an effect.
  function player.extend(src, eff) return player.scope(src):extend(eff) end

  ---Fork eff so it is interrupted when the player drops. Returns the fiber.
  function player.fork(src, eff, opts)
    local fiber = Fx.runFork(eff, opts)
    player.scope(src):unsafeAttachFiber(fiber)
    return fiber
  end

  ---Run fn (or an effect) when the player drops.
  function player.onDrop(src, fin)
    player.scope(src):unsafeAddFinalizer(function()
      if Fx.isEffect(fin) then return fin end
      return Fx.sync(fin)
    end)
  end

  if Fx.isServer and AddEventHandler then
    AddEventHandler('playerDropped', function(reason)
      local src = tonumber(source)
      local s = scopes[src]
      scopes[src] = nil
      if s then
        Fx.runFork(s:close(Fx.Exit.failCause(Fx.Cause.interrupt(0))))
      end
    end)
  end

  return player
end
