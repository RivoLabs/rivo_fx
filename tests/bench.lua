-- Microbenchmarks: lua5.4 tests/bench.lua
-- Plain Lua 5.4 on the virtual platform, so this measures interpreter
-- overhead only (no game, no network).
local root = arg[0]:match('^(.*)tests/bench%.lua$') or './'
package.path = root .. '?.lua;' .. package.path
_G.RIVO_FX_ROOT = root
local Fx = dofile(root .. 'init.lua')
local p = require('tests.platform').new()
Fx.setPlatform(p)

local function bench(name, n, build)
  local eff = build(n)
  collectgarbage('collect')
  local t0 = os.clock()
  local done
  Fx.runFork(eff, { onExit = function(e) done = e end })
  p.run()
  local dt = os.clock() - t0
  assert(done and done._tag == 'Success', name .. ' failed')
  print(('%-34s %9d ops  %8.1f ms  %6.2f µs/op'):format(name, n, dt * 1000, dt * 1e6 / n))
end

bench('flatMap chain', 1000000, function(n)
  local function go(i) if i == 0 then return Fx.unit end
    return Fx.succeed(i):flatMap(function() return go(i - 1) end) end
  return Fx.suspend(function() return go(n) end)
end)

bench('Fx.gen + Fx.yield', 200000, function(n)
  return Fx.gen(function()
    local s = 0
    for i = 1, n do s = s + Fx.yield(Fx.succeed(i)) end
    return s
  end)
end)

bench('catchTag on failure', 200000, function(n)
  local E = Fx.TaggedError('E')
  local items = {}
  for i = 1, n do items[i] = i end
  return Fx.forEach(items, function()
    return E {}:fail():catchTag('E', function() return Fx.unit end)
  end, { discard = true })
end)

bench('fork + join', 50000, function(n)
  local items = {}
  for i = 1, n do items[i] = i end
  return Fx.forEach(items, function(i) return Fx.succeed(i):fork():flatMap(function(f) return f:join() end) end, { discard = true })
end)

bench('schema struct validate', 200000, function(n)
  local S = Fx.S
  local schema = S.struct { amount = S.int:between(1, 1e6), note = S.string:maxLen(32):optional() }
  return Fx.sync(function()
    for _ = 1, n do schema:validate({ amount = 500, note = 'rent' }) end
  end)
end)

bench('stream map + filter (per value)', 500000, function(n)
  return Fx.Stream.range(1, n):map(function(x) return x * 2 end)
    :filter(function(x) return x % 3 ~= 0 end):runDrain()
end)

bench('stream from callbacks (per value)', 200000, function(n)
  return Fx.Stream.async(function(push, finish)
    for i = 1, n do push(i) end
    finish()
  end, { buffer = n }):runDrain()
end)

bench('withSpan (per span)', 200000, function(n)
  local items = {}
  for i = 1, n do items[i] = i end
  return Fx.forEach(items, function(i) return Fx.succeed(i):withSpan('bench') end, { discard = true })
end)

bench('counter inc with labels', 1000000, function(n)
  local c = Fx.metrics.counter('bench_total')
  return Fx.sync(function()
    local labels = { route = 'a' }
    for _ = 1, n do c:inc(1, labels) end
  end)
end)
