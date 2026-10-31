-- Fiber wake benchmark: lua5.4 tests/bench_wake.lua [fibers] [frames]
-- A minimal Citizen scheduler (bookmarks, Wait, the AwaitSentinel protocol)
-- drives the real citizen platform, so this times a full Fx.sleep wake:
-- timer pump, reattach, interpreter, gen resume and re-park.
local root = arg[0]:match('^(.*)tests/bench_wake%.lua$') or './'
package.path = root .. '?.lua;' .. package.path
_G.RIVO_FX_ROOT = root
local now = 0
function GetGameTimer() return now end
local threads = {}   -- runnable: {co, wakeAt, arg}
local AwaitSentinel = setmetatable({}, {__name='sentinel'})
local function resumeThread(co, ...)
  local ok, a = coroutine.resume(co, ...)
  if not ok then error(a) end
  if coroutine.status(co) == 'dead' then return end
  if a == AwaitSentinel then
    local attached = true
    local reattach = function() resumeThread(co) end
    return resumeThread(co, reattach)
  elseif type(a) == 'number' then
    threads[#threads+1] = { co = co, at = now + a }
  end
end
Citizen = {}
function Citizen.CreateThread(fn) threads[#threads+1] = { co = coroutine.create(fn), at = now } end
function Citizen.CreateThreadNow(fn) resumeThread(coroutine.create(fn)) end
function Citizen.Wait(ms) coroutine.yield(ms) end
function Citizen.Await(p) return AwaitSentinel end
CreateThread, Wait = Citizen.CreateThread, Citizen.Wait
function IsDuplicityVersion() return false end
local Fx = dofile(root .. 'init.lua')
assert(Fx.getPlatform().native, 'sentinel not found')
local N, PERIOD, FRAMES = tonumber(arg[1]) or 100, 100, tonumber(arg[2]) or 3000
local wakes = 0
for i = 1, N do Fx.runFork(Fx.gen(function() while true do Fx.yield(Fx.sleep(PERIOD)); wakes = wakes + 1 end end)) end
local t0 = os.clock()
for f = 1, FRAMES do
  now = now + 16
  local run = threads; threads = {}
  for _, t in ipairs(run) do
    if t.at <= now then resumeThread(t.co) else threads[#threads+1] = t end
  end
end
local dt = os.clock() - t0
print(('%d fibers, %d wakes in %.1f ms: %.2f us/wake'):format(N, wakes, dt * 1000, dt * 1e6 / wakes))
