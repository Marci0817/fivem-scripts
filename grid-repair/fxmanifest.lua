fx_version 'cerulean'
game 'gta5'

author 'your-name'
description 'grid-repair — framework-agnostic (ESX / QBCore / Qbox / standalone) via fivem-bridge'
version '0.1.0'

-- The bridge is EMBEDDED in this resource (never a shared dependency).
shared_script 'bridge/shared.lua'

shared_script 'config.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua', -- only needed for the standalone money/persistence fallback
    'bridge/server.lua',
    'server/main.lua',
}

client_scripts {
    'bridge/client.lua',
    'client/main.lua',
}

-- One compact overlay widget: the fuse-sequence minigame. The Lua plumbing
-- (SendNUIMessage / RegisterNUICallback) lives in client/main.lua; the widget
-- itself is a placeholder for the nui-developer stage. See client/main.lua
-- "NUI CONTRACT" for the message shape.
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

-- No SQL: outage state is ephemeral in-memory server state, not player data.
