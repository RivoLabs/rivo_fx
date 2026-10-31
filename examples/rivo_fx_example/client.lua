local S = Fx.S

Results = {}

local function record(key, eff)
  Fx.runFork(eff, { onExit = function(exit) Results[key] = exit end })
end

Fx.net.handle('example:balance', S.struct { balance = S.int }, function(input)
  LastBalance = input.balance
end)

Fx.rpc.register('example:whoami', { input = S.struct { greeting = S.string } }, function(input)
  return Fx.succeed(input.greeting .. ' from client')
end)

function CallBalance() record('balance', Fx.rpc.call('example:balance', {})) end
function CallWithdraw(n) record('withdraw', Fx.rpc.call('example:withdraw', { amount = n })) end
function CallWithdrawHandled(n)
  record('withdrawHandled', Fx.rpc.call('example:withdraw', { amount = n })
    :catchTag('NotEnoughMoney', function(e) return Fx.succeed('short by ' .. (e.need - e.have)) end))
end
function CallSlow(ms) record('slow', Fx.rpc.call('example:slow', {}, { timeout = ms })) end
function CallCrash() record('crash', Fx.rpc.call('example:crash', {})) end
function CallMissing() record('missing', Fx.rpc.call('example:nope', {})) end
function CallBad() record('bad', Fx.rpc.call('example:withdraw', { amount = 'lots' })) end

function LoadModel(name) record('model', Fx.assets.model(name, { timeout = 3000 })) end

function SpawnScoped()
  record('spawn', Fx.scoped(Fx.gen(function()
    local veh = Fx.yield(Fx.entity.spawnVehicle('adder', vector3(0.0, 0.0, 70.0), 90.0))
    SpawnedVehicle = veh
    ExistedInside = DoesEntityExist(veh)
    return veh
  end)))
end

-- Citizen.Wait inside Fx.gen passes through to the scheduler
function WaitInsideGen()
  record('wait', Fx.gen(function()
    local t0 = GetGameTimer()
    Citizen.Wait(200)
    return GetGameTimer() - t0
  end))
end
