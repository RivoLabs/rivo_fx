-- Client: /__NAME__ <item> [qty]
RegisterCommand('__NAME__', function(_, args)
  local item, qty = args[1] or 'water', tonumber(args[2]) or 1
  Fx.runFork(Fx.gen(function()
    local receipt = Fx.yield(Fx.rpc.call('__NAME__:buy', { item = item, qty = qty }, { timeout = 5000 }))
    print(('Bought %dx %s for $%d, $%d cash left'):format(receipt.qty, receipt.item, receipt.paid, receipt.cash))
  end)
    :catchTag('InsufficientFunds', function(e)
      print(('Not enough cash: need $%d, have $%d'):format(e.need, e.have))
      return Fx.unit
    end)
    :catchTag('RpcInvalidInput', function(e)
      print('Bad order: ' .. e.message)
      return Fx.unit
    end))
end, false)
