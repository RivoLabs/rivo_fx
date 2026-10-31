fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name '__NAME__'
description '__NAME__: made with Rivo FX'

dependency 'rivo_fx'
shared_scripts {
  '@rivo_fx/init.lua',
  'shared/schemas.lua', -- generated: npx rivo-fx gen shared/schemas.json --lua shared/schemas.lua --namespace __NAMESPACE__
}
server_script 'server.lua'
client_script 'client.lua'

ui_page 'web/index.html'
files { 'web/index.html', 'web/app.js', 'web/fx-nui.js' }
