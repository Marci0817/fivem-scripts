--[[
    fivem-bridge :: bridge/client.lua
    Client-side adapter. Normalizes notifications across frameworks, with a
    native GTA fallback so it always works — even standalone.
]]

local FW = Bridge.Framework

--- One notify call that works everywhere.
---@param msg string
---@param type? 'inform'|'success'|'error'|'warning'
function Bridge.Notify(msg, type)
    type = type or 'inform'
    if FW == 'esx' then
        TriggerEvent('esx:showNotification', msg)
    elseif FW == 'qb' or FW == 'qbox' then
        TriggerEvent('QBCore:Notify', msg, type)
    elseif GetResourceState('ox_lib') == 'started' then
        exports.ox_lib:notify({ description = msg, type = type })
    else
        -- Standalone fallback: native GTA feed notification.
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(msg)
        EndTextCommandThefeedPostTicker(false, true)
    end
end
