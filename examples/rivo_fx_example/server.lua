local S = Fx.S

-- Errors -----------------------------------------------------------------------
local NotEnoughMoney = Fx.TaggedError('NotEnoughMoney')

-- Services ---------------------------------------------------------------------
---@class BankService
---@field balance fun(src: integer): Fx.Effect<integer, never>
---@field deposit fun(src: integer, amount: integer): Fx.Effect<integer, never>
---@field withdraw fun(src: integer, amount: integer): Fx.Effect<integer, Fx.TaggedError>

local Bank = Fx.Tag('Bank')

local BankLive = Fx.Layer.scoped(Bank, Fx.gen(function()
  local accounts = {}
  -- released when the resource stops
  Fx.yield(Fx.addFinalizer(function()
    return Fx.sync(function() print('bank: closed accounts') end)
  end))
  local function get(src) return accounts[src] or 0 end
  return {
    balance = function(src) return Fx.sync(function() return get(src) end) end,
    deposit = function(src, amount)
      return Fx.sync(function()
        accounts[src] = get(src) + amount
        return accounts[src]
      end)
    end,
    withdraw = function(src, amount)
      return Fx.suspend(function()
        local have = get(src)
        if have < amount then return NotEnoughMoney { have = have, need = amount }:fail() end
        accounts[src] = have - amount
        return Fx.succeed(accounts[src])
      end)
    end,
  }
end))

Fx.setRuntime(Fx.Runtime.make(BankLive))

-- Security log, readable by tests --------------------------------------------
SecurityLog = {}
Fx.security.on(function(ev) SecurityLog[#SecurityLog + 1] = ev end)

-- Net events -------------------------------------------------------------------
local Deposit = S.struct {
  amount = S.int:between(1, 1000000),
  note = S.string:maxLen(32):optional(),
}

Fx.net.handle('example:deposit', Deposit, function(src, input)
  return Fx.gen(function()
    local bank = Fx.yield(Bank) ---@type BankService
    local balance = Fx.yield(bank.deposit(src, input.amount))
    Fx.yield(Fx.net.emit('example:balance', src, { balance = balance }))
  end)
end, { rateLimit = '5/s' })

-- RPC --------------------------------------------------------------------------
Fx.rpc.register('example:balance', { input = S.struct {} }, function(src)
  return Bank:flatMap(function(bank) return bank.balance(src) end)
end)

Fx.rpc.register('example:withdraw', { input = S.struct { amount = S.int:positive() } }, function(src, input)
  return Bank:flatMap(function(bank) return bank.withdraw(src, input.amount) end)
end)

SlowInterrupted = false
Fx.rpc.register('example:slow', { input = S.unknown }, function()
  return Fx.sleep(5000):as('late'):onInterrupt(function()
    return Fx.sync(function() SlowInterrupted = true end)
  end)
end)

Fx.rpc.register('example:crash', { input = S.unknown }, function()
  return Fx.sync(function() error('secret internal detail') end)
end)

-- Server -> client RPC
function AskClientName(src)
  ClientAnswer = nil
  Fx.runFork(Fx.rpc.callClient(src, 'example:whoami', { greeting = 'hi' }, { timeout = 2000 }), {
    onExit = function(exit) ClientAnswer = exit end,
  })
end

-- Scoped work tied to the resource lifetime -----------------------------------
Fx.runFork(Fx.scoped(Fx.gen(function()
  Fx.yield(Fx.acquireRelease(Fx.sync(function() return 'ticker' end), function(name)
    return Fx.sync(function() print('released ' .. name) end)
  end))
  Fx.yield(Fx.never)
end)))

Fx.onStop(function() print('example: onStop ran') end)
