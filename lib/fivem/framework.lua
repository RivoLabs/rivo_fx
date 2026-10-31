-- One player/money/job API over ESX, QBCore, Qbox and standalone (server).
--   Fx.setRuntime(Fx.Runtime.make(Fx.framework.auto))
--   local fw = Fx.yield(Fx.framework.Framework)
--   local p = Fx.yield(fw.getPlayer(src))          -- fails PlayerNotFound
--   Fx.yield(fw.removeMoney(src, 'bank', 500, 'garage fee'))
--     :catchTag('InsufficientFunds', ...)
-- A player is normalized to:
--   { source, identifier, name, job = { name, label, grade, gradeLabel }, money = { cash, bank } }
return function(Fx)
  local framework = {}

  framework.PlayerNotFound = Fx.TaggedError('PlayerNotFound')
  framework.InsufficientFunds = Fx.TaggedError('InsufficientFunds')
  framework.FrameworkError = Fx.TaggedError('FrameworkError')

  ---The Framework service tag.
  framework.Framework = Fx.Tag('rivo_fx/Framework')

  local ACCOUNTS = { cash = true, bank = true }

  local function checkAccount(account, amount)
    if not ACCOUNTS[account] then
      return framework.FrameworkError { message = ('unknown account %q (use "cash" or "bank")'):format(tostring(account)) }
    end
    if amount ~= nil and (type(amount) ~= 'number' or amount < 0 or amount ~= amount or amount == math.huge) then
      return framework.FrameworkError { message = ('invalid amount %s'):format(tostring(amount)) }
    end
  end

  ---Build a Framework service from per-framework primitives:
  ---  find(src) -> handle|nil, describe(src, handle) -> player,
  ---  balance(src, handle, account) -> number (read live, never from a copy), add(src, handle, account, amount, reason) -> boolean,
  ---  remove(src, handle, account, amount, reason) -> boolean,
  ---  setJob(src, handle, name, grade) -> boolean (optional),
  ---  events = { loaded, unloaded, job } names with *Args mapping their arguments.
  local function make(name, p)
    local svc = { name = name }

    local function withPlayer(src, f)
      return Fx.suspend(function()
        local ok, handle = pcall(p.find, src)
        if not ok then return Fx.fail(framework.FrameworkError { message = tostring(handle) }) end
        if handle == nil then return Fx.fail(framework.PlayerNotFound { source = src }) end
        return f(handle)
      end)
    end

    function svc.getPlayer(src)
      return withPlayer(src, function(h) return Fx.succeed(p.describe(src, h)) end)
    end

    ---The player, or nil when they have no character loaded.
    function svc.findPlayer(src)
      return svc.getPlayer(src):catchTag('PlayerNotFound', function() return Fx.succeed(nil) end)
    end

    function svc.getMoney(src, account)
      local bad = checkAccount(account)
      if bad then return Fx.fail(bad) end
      return withPlayer(src, function(h) return Fx.succeed(p.balance(src, h, account)) end)
    end

    function svc.addMoney(src, account, amount, reason)
      local bad = checkAccount(account, amount)
      if bad then return Fx.fail(bad) end
      return withPlayer(src, function(h)
        if p.add(src, h, account, amount, reason or Fx.resourceName) == false then
          return Fx.fail(framework.FrameworkError { message = 'the framework refused to add money' })
        end
        return Fx.succeed(p.balance(src, h, account))
      end)
    end

    ---Fails with InsufficientFunds { source, account, need, have } instead of
    ---going negative.
    function svc.removeMoney(src, account, amount, reason)
      local bad = checkAccount(account, amount)
      if bad then return Fx.fail(bad) end
      return withPlayer(src, function(h)
        local have = p.balance(src, h, account)
        if have < amount then
          return Fx.fail(framework.InsufficientFunds { source = src, account = account, need = amount, have = have })
        end
        if p.remove(src, h, account, amount, reason or Fx.resourceName) == false then
          return Fx.fail(framework.InsufficientFunds { source = src, account = account, need = amount, have = p.balance(src, h, account) })
        end
        return Fx.succeed(p.balance(src, h, account))
      end)
    end

    ---Set a player's job. Succeeds with the new job; fails with
    ---FrameworkError when the job or grade does not exist.
    function svc.setJob(src, jobName, grade)
      grade = grade or 0
      return withPlayer(src, function(h)
        if not p.setJob or p.setJob(src, h, jobName, grade) == false then
          return Fx.fail(framework.FrameworkError {
            message = ('job %s grade %s does not exist in %s'):format(tostring(jobName), tostring(grade), name),
          })
        end
        return Fx.succeed(p.describe(src, p.find(src)).job)
      end)
    end

    -- Events. The service tracks which players have a character loaded, so
    -- "unloaded" fires exactly once whether the framework reports a logout or
    -- the player just drops (Qbox only reports logouts), whatever order the
    -- resources' playerDropped handlers run in.
    local ev = p.events
    local handlers = { loaded = {}, unloaded = {}, job = {} }
    local loaded = {}

    local function emit(kind, src, extra)
      for _, fn in ipairs(handlers[kind]) do
        local ok, res = pcall(fn, src, extra)
        if not ok then Fx._reportDefect(('framework %s handler'):format(kind), res)
        elseif Fx.isEffect(res) then Fx.runFork(res) end
      end
    end

    local function unload(src)
      if src and loaded[src] then
        loaded[src] = nil
        emit('unloaded', src)
      end
    end

    if AddEventHandler then
      for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local ok, h = pcall(p.find, src)
        if ok and h ~= nil then loaded[src] = true end
      end
      if ev.loaded then
        AddEventHandler(ev.loaded, function(...)
          local src = ev.loadedArgs(...)
          if src == nil then return end
          loaded[src] = true
          emit('loaded', src)
        end)
      end
      if ev.unloaded then
        AddEventHandler(ev.unloaded, function(...) unload(ev.unloadedArgs(...)) end)
      end
      AddEventHandler('playerDropped', function() unload(tonumber(source)) end)
      if ev.job then
        AddEventHandler(ev.job, function(...)
          local src, job = ev.jobArgs(...)
          emit('job', src, job)
        end)
      end
    end

    local function on(kind, fn)
      local list = handlers[kind]
      list[#list + 1] = fn
      return function()
        for i = #list, 1, -1 do if list[i] == fn then table.remove(list, i) end end
      end
    end

    ---fn(src) when a player's character is loaded. fn may return an effect.
    ---Returns a function that removes the handler.
    function svc.onPlayerLoaded(fn) return on('loaded', fn) end
    ---fn(src) once when a character is unloaded (logout or drop).
    function svc.onPlayerUnloaded(fn) return on('unloaded', fn) end
    ---fn(src, job) when a player's job changes; job is { name, label, grade, gradeLabel }.
    function svc.onJobChange(fn) return on('job', fn) end

    return svc
  end

  -- ESX ----------------------------------------------------------------------

  local ESX_ACCOUNT = { cash = 'money', bank = 'bank' }

  local function esx()
    local ESX = exports.es_extended:getSharedObject()
    local function job(j)
      j = j or {}
      return { name = j.name, label = j.label, grade = j.grade, gradeLabel = j.grade_label }
    end
    return make('esx', {
      find = function(src) return ESX.GetPlayerFromId(src) end,
      describe = function(src, x)
        return {
          source = src, identifier = x.identifier, name = x.getName(), job = job(x.job),
          money = { cash = x.getAccount('money').money, bank = x.getAccount('bank').money },
        }
      end,
      balance = function(_, x, account) return x.getAccount(ESX_ACCOUNT[account]).money end,
      add = function(_, x, account, amount, reason) x.addAccountMoney(ESX_ACCOUNT[account], amount, reason) end,
      remove = function(_, x, account, amount, reason) x.removeAccountMoney(ESX_ACCOUNT[account], amount, reason) end,
      setJob = function(_, x, jobName, grade)
        if not ESX.DoesJobExist(jobName, tostring(grade)) then return false end
        x.setJob(jobName, grade)
      end,
      events = {
        loaded = 'esx:playerLoaded', loadedArgs = function(src) return src end,
        unloaded = 'esx:playerDropped', unloadedArgs = function(src) return src end,
        job = 'esx:setJob', jobArgs = function(src, j) return src, job(j) end,
      },
    })
  end

  -- QBCore and Qbox (same PlayerData) ---------------------------------------

  local function qbJob(j)
    j = j or {}
    local grade = j.grade or {}
    return { name = j.name, label = j.label, grade = grade.level, gradeLabel = grade.name }
  end

  local QB_EVENTS = {
    loaded = 'QBCore:Server:PlayerLoaded', loadedArgs = function(player) return player.PlayerData.source end,
    unloaded = 'QBCore:Server:OnPlayerUnload', unloadedArgs = function(src) return src end,
    job = 'QBCore:Server:OnJobUpdate', jobArgs = function(src, j) return src, qbJob(j) end,
  }

  local function describeQb(src, player)
    local d = player.PlayerData
    local ci = d.charinfo or {}
    local name = ci.firstname and ((ci.firstname or '') .. ' ' .. (ci.lastname or '')) or GetPlayerName(src)
    return {
      source = src, identifier = d.citizenid, name = name, job = qbJob(d.job),
      money = { cash = d.money.cash, bank = d.money.bank },
    }
  end

  local function qbcore()
    local QBCore = exports['qb-core']:GetCoreObject()
    return make('qbcore', {
      find = function(src) return QBCore.Functions.GetPlayer(src) end,
      describe = describeQb,
      -- tables that cross an export are copies: read the balance again
      balance = function(src, _, account) return QBCore.Functions.GetPlayer(src).PlayerData.money[account] end,
      add = function(_, player, account, amount, reason) return player.Functions.AddMoney(account, amount, reason) end,
      remove = function(_, player, account, amount, reason) return player.Functions.RemoveMoney(account, amount, reason) end,
      setJob = function(_, player, jobName, grade) return player.Functions.SetJob(jobName, tostring(grade)) end,
      events = QB_EVENTS,
    })
  end

  local function qbox()
    local qbx = exports.qbx_core
    return make('qbox', {
      find = function(src) return qbx:GetPlayer(src) end,
      describe = describeQb,
      balance = function(src, _, account) return qbx:GetMoney(src, account) end,
      add = function(src, _, account, amount, reason) return qbx:AddMoney(src, account, amount, reason) end,
      remove = function(src, _, account, amount, reason) return qbx:RemoveMoney(src, account, amount, reason) end,
      setJob = function(src, _, jobName, grade) return qbx:SetJob(src, jobName, grade) end,
      events = QB_EVENTS,
    })
  end

  -- Standalone: no characters; money lives in memory per session -------------

  local function standalone()
    local wallets = {}
    local function wallet(src)
      wallets[src] = wallets[src] or { cash = 0, bank = 0 }
      return wallets[src]
    end
    if AddEventHandler then
      AddEventHandler('playerDropped', function() wallets[source] = nil end)
    end
    return make('standalone', {
      find = function(src)
        if GetPlayerName(src) == nil then return nil end
        return wallet(src)
      end,
      describe = function(src, w)
        return {
          source = src, identifier = GetPlayerIdentifierByType(src, 'license'), name = GetPlayerName(src),
          job = { name = 'unemployed', label = 'Unemployed', grade = 0, gradeLabel = 'Unemployed' },
          money = { cash = w.cash, bank = w.bank },
        }
      end,
      balance = function(_, w, account) return w[account] end,
      add = function(_, w, account, amount) w[account] = w[account] + amount end,
      remove = function(_, w, account, amount) w[account] = w[account] - amount end,
      events = { loaded = 'playerJoining', loadedArgs = function() return tonumber(source) end },
    })
  end

  local builders = { esx = esx, qbcore = qbcore, qbox = qbox, standalone = standalone }

  ---Which framework is running: 'qbox' | 'qbcore' | 'esx' | 'standalone'.
  function framework.detect()
    local function started(res) return GetResourceState(res) == 'started' end
    if started('qbx_core') then return 'qbox' end
    if started('qb-core') then return 'qbcore' end
    if started('es_extended') then return 'esx' end
    return 'standalone'
  end

  -- One service per framework per resource: building it registers event
  -- handlers, so every provide of a layer shares it.
  local built = {}
  local function get(name)
    built[name] = built[name] or builders[name]()
    return built[name]
  end

  local function layer(name)
    return Fx.Layer.sync(framework.Framework, function() return get(name) end)
  end

  framework.esx = layer('esx')
  framework.qbcore = layer('qbcore')
  framework.qbox = layer('qbox')
  framework.standalone = layer('standalone')
  ---Picks the running framework when built.
  framework.auto = Fx.Layer.sync(framework.Framework, function() return get(framework.detect()) end)

  return framework
end
