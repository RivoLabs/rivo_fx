-- Frame-bound work that stops cleanly.
--   Fx.runFork(Fx.tick.whileNear(vector3(441.0, -982.0, 30.7), 10.0, function()
--     DrawMarker(...)
--   end))
-- The per-frame function runs on one plain Citizen thread (the cheapest way
-- to run something every frame) and stops when the fiber is interrupted or
-- its scope closes. If it raises, the effect fails with that defect.
return function(Fx)
  local tick = {}

  ---Run fn every frame until interrupted.
  ---@param fn fun()
  function tick.everyFrame(fn)
    return Fx.async(function(resume)
      local running = true
      CreateThread(function()
        while running do
          local ok, err = pcall(fn)
          if not ok then
            running = false
            resume(Fx.die(err))
            return
          end
          Wait(0)
        end
      end)
      return function() running = false end
    end)
  end

  ---Run fn every frame while the local player is within radius of coords.
  ---The distance is checked every opts.checkMs (default 500) while away, so
  ---being far costs almost nothing. Client only.
  ---@param coords vector3|{ x: number, y: number, z: number }
  ---@param radius number
  ---@param fn fun(distance: number)
  ---@param opts? { checkMs?: integer }
  function tick.whileNear(coords, radius, fn, opts)
    local checkMs = opts and opts.checkMs or 500
    local center = vector3(coords.x, coords.y, coords.z)
    return Fx.async(function(resume)
      local running = true
      CreateThread(function()
        while running do
          local d = #(GetEntityCoords(PlayerPedId()) - center)
          if d <= radius then
            local ok, err = pcall(fn, d)
            if not ok then
              running = false
              resume(Fx.die(err))
              return
            end
            Wait(0)
          else
            Wait(checkMs)
          end
        end
      end)
      return function() running = false end
    end)
  end

  ---Run fn every frame while condition() is true, checking it every
  ---opts.checkMs (default 250) while false.
  ---@param condition fun(): boolean
  ---@param fn fun()
  function tick.whileTrue(condition, fn, opts)
    local checkMs = opts and opts.checkMs or 250
    return Fx.async(function(resume)
      local running = true
      CreateThread(function()
        while running do
          local okc, active = pcall(condition)
          if not okc then
            running = false
            resume(Fx.die(active))
            return
          end
          if active then
            local ok, err = pcall(fn)
            if not ok then
              running = false
              resume(Fx.die(err))
              return
            end
            Wait(0)
          else
            Wait(checkMs)
          end
        end
      end)
      return function() running = false end
    end)
  end

  return tick
end
