-- Server: one validated, rate-limited RPC that charges the player through
-- whatever framework runs (ESX, QBCore, Qbox, or none).
local PRICES = { water = 5, bread = 8, phone = 450 }

Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))

Fx.rpc.register('__NAME__:buy', { input = __NAMESPACE__.BuyInput, output = __NAMESPACE__.Receipt, rateLimit = '5/s' },
  function(src, input)
    return Fx.gen(function()
      local fw = Fx.yield(Fx.framework.Framework)
      local cost = PRICES[input.item] * input.qty
      -- fails with InsufficientFunds, which the client receives as that tag
      local cash = Fx.yield(fw.removeMoney(src, 'cash', cost, '__NAME__ purchase'))
      Fx.yield(Fx.logInfo(('%s bought %dx %s for $%d'):format(GetPlayerName(src), input.qty, input.item, cost)))
      return { item = input.item, qty = input.qty, paid = cost, cash = cash }
    end)
  end)
