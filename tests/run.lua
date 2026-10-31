-- Minimal test runner: lua5.4 tests/run.lua [file ...]
-- Runs every tests/test_*.lua (or the given files) against a fresh Fx with
-- the virtual platform.
local root = arg[0]:match('^(.*)tests/run%.lua$') or './'
package.path = root .. '?.lua;' .. package.path
_G.RIVO_FX_ROOT = root

local Platform = require('tests.platform')

local passed, failed, failures = 0, 0, {}
local current

local T = {}

local function fmt(v)
  if type(v) == 'table' and _G.Fx then return _G.Fx.inspect(v) end
  if type(v) == 'string' then return string.format('%q', v) end
  return tostring(v)
end

local function deepEqual(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
T.deepEqual = deepEqual

function T.eq(actual, expected, msg)
  if not deepEqual(actual, expected) then
    error(('%sexpected %s, got %s'):format(msg and (msg .. ': ') or '', fmt(expected), fmt(actual)), 2)
  end
end

function T.ok(v, msg)
  if not v then error(msg or 'expected truthy value', 2) end
end

function T.match(s, pattern, msg)
  if type(s) ~= 'string' or not s:find(pattern) then
    error(('%sexpected %s to match %q'):format(msg and (msg .. ': ') or '', fmt(s), pattern), 2)
  end
end

---Fresh Fx + virtual platform for each test.
function T.fresh()
  _G.Fx = nil
  local Fx = dofile(root .. 'init.lua')
  local p = Platform.new()
  Fx.setPlatform(p)
  return Fx, p
end

---Run eff to completion on the virtual platform; returns its Exit.
function T.runExit(Fx, p, eff, limit)
  local exit
  Fx.runFork(eff, { onExit = function(e) exit = e end })
  p.run(limit)
  return exit
end

---Run and return the value, failing the test on failure.
function T.run(Fx, p, eff, limit)
  local exit = T.runExit(Fx, p, eff, limit)
  if not exit then error('effect did not finish', 2) end
  if exit._tag ~= 'Success' then error('effect failed: ' .. Fx.Cause.pretty(exit.cause), 2) end
  return exit.value
end

function T.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    io.write('  \27[32m✓\27[0m ', name, '\n')
  else
    failed = failed + 1
    failures[#failures + 1] = current .. ' › ' .. name .. '\n' .. tostring(err)
    io.write('  \27[31m✗\27[0m ', name, '\n')
  end
end

local files = {}
if #arg > 0 then
  for i = 1, #arg do files[#files + 1] = arg[i] end
else
  local p = io.popen('ls ' .. root .. 'tests/test_*.lua')
  for line in p:lines() do files[#files + 1] = line end
  p:close()
end

for _, file in ipairs(files) do
  current = file:match('([^/]+)%.lua$')
  io.write(current, '\n')
  local chunk = assert(loadfile(file))
  chunk(T)
end

io.write(('\n%d passed, %d failed\n'):format(passed, failed))
if failed > 0 then
  for _, f in ipairs(failures) do io.write('\n\27[31m', f, '\27[0m\n') end
  os.exit(1)
end
