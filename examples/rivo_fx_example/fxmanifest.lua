fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'rivo_fx_example'
description 'Rivo FX example: a tiny bank with validated events, RPC, layers and scopes'

dependency 'rivo_fx'
shared_script '@rivo_fx/init.lua'
server_script 'server.lua'
client_script 'client.lua'
