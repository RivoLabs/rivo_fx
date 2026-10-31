fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'rivo_fx'
author 'Rivo'
version '1.0.0'
description 'Effect-style typed systems for FiveM: typed errors, fibers, Layers, Schema, validated net events'
repository 'https://github.com/RivoLabs/rivo_fx'

-- Consumers load the library into their own runtime:
--   dependency 'rivo_fx'
--   shared_script '@rivo_fx/init.lua'
-- rivo_fx's own scripts: the telemetry endpoint (server/hub.lua) and the
-- /fxdev devtools (server/devtools.lua, client/devtools.lua, ui/).
shared_scripts {
  'init.lua',
  'shared/collect.lua',
}
server_scripts {
  'server/hub.lua',
  'server/devtools.lua',
}
client_script 'client/devtools.lua'

ui_page 'ui/devtools.html'

files {
  'init.lua',
  'lib/core/*.lua',
  'lib/fivem/*.lua',
  'ui/devtools.html',
  'ui/devtools.css',
  'ui/devtools.js',
  'ui/fonts/*.woff2',
}
