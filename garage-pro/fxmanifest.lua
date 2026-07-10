fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'garage-pro'
author 'your-name'
description 'garage-pro — framework-agnostic (ESX / QBCore / Qbox / standalone) via fivem-bridge'
version '0.1.0'

-- OneSync must be enabled: server-side vehicle creation (CreateVehicleServerSetter)
-- and the impound sweep (GetAllVehicles) both require it.
--
-- Import sql/garage_pro.sql once via oxmysql before first start (manual import
-- required — it is NOT run automatically).
dependency 'oxmysql'

-- The bridge is EMBEDDED in this resource (never a shared dependency).
shared_script 'bridge/shared.lua'

shared_script 'config.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua', -- required: vehicle persistence + standalone money fallback
    'bridge/server.lua',
    'server/main.lua',
}

client_scripts {
    'bridge/client.lua',
    'client/main.lua',
}
