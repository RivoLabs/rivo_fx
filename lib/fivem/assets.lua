-- Client: load streamed assets with timeouts and typed errors instead of
-- `while not HasModelLoaded(m) do Wait(0) end`.
--
--   local hash = Fx.yield(Fx.assets.model('adder', { timeout = 5000 }))
--   -- scoped: released when the scope closes
--   Fx.yield(Fx.assets.useModel('adder'))
return function(Fx)
  local assets = {}

  assets.AssetNotFound = Fx.TaggedError('AssetNotFound')
  assets.AssetTimeout = Fx.TaggedError('AssetTimeout')

  local DEFAULT_TIMEOUT = 10000

  ---Effect that checks check() every frame until it returns true.
  ---Fails with onTimeout() after timeout ms.
  function Fx.poll(check, timeout, onTimeout)
    local loop
    loop = function()
      return Fx.suspend(function()
        if check() then return Fx.unit end
        return Fx.sleep(0):zipRight(loop())
      end)
    end
    return loop():timeoutFail(timeout, onTimeout)
  end

  local function loader(kind, def)
    local load = function(name, opts)
      local timeout = opts and opts.timeout or DEFAULT_TIMEOUT
      return Fx.suspend(function()
        local id = def.resolve and def.resolve(name) or name
        if def.exists and not def.exists(id) then
          return Fx.fail(assets.AssetNotFound { kind = kind, name = name })
        end
        local handle = def.request(id)
        local key = handle or id
        return Fx.poll(function() return def.loaded(key) end, timeout, function()
          return assets.AssetTimeout { kind = kind, name = name, timeoutMs = timeout }
        end):as(key)
      end)
    end
    local use = function(name, opts)
      return load(name, opts):flatMap(function(key)
        return Fx.acquireRelease(Fx.succeed(key), function(k)
          return Fx.sync(function() def.release(k) end)
        end)
      end)
    end
    return load, use
  end

  local function hashOf(m)
    if type(m) == 'string' then return joaat(m) end
    return m
  end

  ---Load a model; succeeds with its hash.
  assets.model, assets.useModel = loader('model', {
    resolve = hashOf,
    exists = function(h) return IsModelInCdimage(h) and IsModelValid(h) end,
    request = function(h) RequestModel(h) end,
    loaded = HasModelLoaded,
    release = SetModelAsNoLongerNeeded,
  })

  assets.animDict, assets.useAnimDict = loader('animDict', {
    exists = DoesAnimDictExist,
    request = function(d) RequestAnimDict(d) end,
    loaded = HasAnimDictLoaded,
    release = RemoveAnimDict,
  })

  assets.animSet, assets.useAnimSet = loader('animSet', {
    request = function(s) RequestAnimSet(s) end,
    loaded = HasAnimSetLoaded,
    release = RemoveAnimSet,
  })

  assets.ptfx, assets.usePtfx = loader('ptfx', {
    request = function(a) RequestNamedPtfxAsset(a) end,
    loaded = HasNamedPtfxAssetLoaded,
    release = RemoveNamedPtfxAsset,
  })

  assets.textureDict, assets.useTextureDict = loader('textureDict', {
    request = function(d) RequestStreamedTextureDict(d, false) end,
    loaded = HasStreamedTextureDictLoaded,
    release = SetStreamedTextureDictAsNoLongerNeeded,
  })

  ---Succeeds with the scaleform handle.
  assets.scaleform, assets.useScaleform = loader('scaleform', {
    request = function(name) return RequestScaleformMovie(name) end,
    loaded = HasScaleformMovieLoaded,
    release = SetScaleformMovieAsNoLongerNeeded,
  })

  assets.audioBank, assets.useAudioBank = loader('audioBank', {
    request = function(b) RequestScriptAudioBank(b, false) end,
    loaded = function(b) return RequestScriptAudioBank(b, false) end,
    release = ReleaseNamedScriptAudioBank,
  })

  return assets
end
