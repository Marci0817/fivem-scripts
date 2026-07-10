fx_version 'cerulean'
game 'gta5'

author 'your-name'
description 'waybill-delivery — framework-agnostic (ESX / QBCore / Qbox / standalone) via fivem-bridge'
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

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/script.js',
}

-- No SQL: waybill state is transient per delivery run (see DEVNOTES.md).
