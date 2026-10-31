-- Client: /__NAME__ opens the shop page. The page calls 'buy' and 'close';
-- both are typed: the page gets the receipt or a tagged error back.
local open = nil -- the fiber that holds focus while the page is open

Fx.nui.handle('buy', { input = __NAMESPACE__.BuyInput }, function(input)
  -- the server's typed errors (InsufficientFunds, RpcInvalidInput, ...) reach the page as their tag
  return Fx.rpc.call('__NAME__:buy', input, { timeout = 5000 })
end)

Fx.nui.handle('close', { input = Fx.S.struct {} }, function()
  if open then open:interruptAsFork(0) end
  return true
end)

RegisterCommand('__NAME__', function()
  if open then return end
  -- focus is held for the life of this scope and released however it ends
  open = Fx.runFork(Fx.scoped(Fx.gen(function()
    Fx.yield(Fx.nui.useFocus())
    Fx.yield(Fx.nui.send('open', { items = { 'water', 'bread', 'phone' } }))
    Fx.yield(Fx.never)
  end)):ensuring(Fx.sync(function()
    open = nil
    SendNUIMessage({ type = 'close' })
  end)))
end, false)
