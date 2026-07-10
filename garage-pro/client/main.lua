--[[
    garage-pro :: client/main.lua

    Presentation and requests only. The client draws blips/markers/help text,
    reads the [E] key, opens a choice list (ox_lib menu if present, else a chat
    list + /retrieve command), and seats the player once a retrieved vehicle has
    streamed in. Every decision — ownership, money, spawning — is the server's.

    The one bridge call here is Bridge.Notify, so feedback works on ESX, QB,
    Qbox, ox_lib or bare GTA. This mirrors products/garage/client.lua; garage-pro
    only adds garage TYPES and the impound/reclaim menu.
]]

local E = 38  -- INPUT_PICKUP ([E] by default)

local function dbg(...)
    if Config.Debug then print('[garage-pro]', ...) end
end

--------------------------------------------------------------------------------
-- Blips (one per garage; sprite/colour chosen by type). Cleaned up on stop.
--------------------------------------------------------------------------------

local blips = {}

CreateThread(function()
    for _, g in ipairs(Config.Garages) do
        local cfg  = Config.Blip[g.type] or Config.Blip.personal
        local blip = AddBlipForCoord(g.coords.x, g.coords.y, g.coords.z)
        SetBlipSprite(blip, cfg.sprite)
        SetBlipColour(blip, cfg.color)
        SetBlipScale(blip, cfg.scale)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(cfg.label)
        EndTextCommandSetBlipName(blip)
        blips[#blips + 1] = blip
    end
end)

--------------------------------------------------------------------------------
-- Native help text
--------------------------------------------------------------------------------

local function helpText(msg)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

--------------------------------------------------------------------------------
-- Choice list — ox_lib context menu if it is running, chat + /retrieve otherwise
--------------------------------------------------------------------------------

local hasOxLib   = GetResourceState('ox_lib') == 'started'
local pendingList = {}  -- plate -> garageIndex, for the /retrieve fallback

-- kind is 'retrieve' (stored garage) or 'reclaim' (impound lot); it decides the
-- server event, the header text and the "empty" message.
local function openList(garageIndex, kind, vehicles)
    if #vehicles == 0 then
        Bridge.Notify(kind == 'reclaim' and Config.Messages.impound_no_vehicles
                                          or Config.Messages.retrieve_no_vehicles, 'inform')
        return
    end

    local serverEvent = kind == 'reclaim' and 'garage-pro:reclaim' or 'garage-pro:retrieve'
    local header      = kind == 'reclaim' and Config.Messages.reclaim_prompt
                                           or Config.Messages.retrieve_at_garage

    if hasOxLib then
        local options = {}
        for _, v in ipairs(vehicles) do
            options[#options + 1] = {
                title       = ('%s  [%s]'):format(v.model, v.plate),
                description = kind == 'reclaim' and Config.Messages.option_reclaim
                                                 or Config.Messages.option_take_out,
                onSelect    = function()
                    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                    TriggerServerEvent(serverEvent, v.plate, garageIndex)
                end,
            }
        end
        exports.ox_lib:registerContext({ id = 'garage_pro_menu', title = header, options = options })
        exports.ox_lib:showContext('garage_pro_menu')
        return
    end

    -- Fallback: list in chat, act with /retrieve <plate>.
    pendingList = {}
    TriggerEvent('chat:addMessage', { args = { Config.Messages.chat_header, header } })
    for _, v in ipairs(vehicles) do
        pendingList[v.plate] = { index = garageIndex, event = serverEvent }
        TriggerEvent('chat:addMessage', { args = { v.plate, v.model } })
    end
end

RegisterNetEvent('garage-pro:openList', openList)

RegisterCommand('retrieve', function(_, args)
    local plate = args[1] and args[1]:upper()
    local entry = plate and pendingList[plate]
    if not entry then
        Bridge.Notify(Config.Messages.retrieve_no_pending, 'error')
        return
    end
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    TriggerServerEvent(entry.event, plate, entry.index)
end, false)

--------------------------------------------------------------------------------
-- Fob-click flavour anim (reclaim only). Fully self-cleaning — no frozen ped.
--------------------------------------------------------------------------------

local function playFobClick()
    CreateThread(function()
        local dict = 'anim@mp_player_intmenu@key_fob@'
        RequestAnimDict(dict)
        local tries = 0
        while not HasAnimDictLoaded(dict) and tries < 50 do
            Wait(20)
            tries = tries + 1
        end
        if not HasAnimDictLoaded(dict) then return end

        local ped = PlayerPedId()
        TaskPlayAnim(ped, dict, 'fob_click', 3.0, 3.0, -1, 48, 0.0, false, false, false)
        Wait(1000)
        ClearPedTasks(ped)
        RemoveAnimDict(dict)
    end)
end

RegisterNetEvent('garage-pro:fobClick', playFobClick)

--------------------------------------------------------------------------------
-- Seat the player once the spawned vehicle streams in locally
--------------------------------------------------------------------------------

RegisterNetEvent('garage-pro:vehicleSpawned', function(netId)
    local tries = 0
    while not NetworkDoesEntityExistWithNetworkId(netId) and tries < 100 do
        Wait(10)
        tries = tries + 1
    end
    if not NetworkDoesEntityExistWithNetworkId(netId) then
        dbg('vehicle never streamed in, netId=', netId)
        return
    end
    SetPedIntoVehicle(PlayerPedId(), NetworkGetEntityFromNetworkId(netId), -1)
end)

--------------------------------------------------------------------------------
-- Notify passthrough + money sound (server -> Bridge.Notify)
--------------------------------------------------------------------------------

RegisterNetEvent('garage-pro:notify', function(msg, kind, sound)
    if sound == 'money' then
        PlaySoundFrontend(-1, 'PURCHASE', 'HUD_LIQUOR_STORE_SOUNDSET', true)
    end
    Bridge.Notify(msg, kind)
end)

--------------------------------------------------------------------------------
-- Main loop: marker + [E]. Variable wait — 0.00ms resmon when far away.
--------------------------------------------------------------------------------

CreateThread(function()
    while true do
        local wait = 1000
        local ped  = PlayerPedId()
        local pos  = GetEntityCoords(ped)

        local nearIndex, nearGarage, nearDist
        for i, g in ipairs(Config.Garages) do
            local d = #(pos - g.coords)
            if not nearDist or d < nearDist then
                nearDist, nearIndex, nearGarage = d, i, g
            end
        end

        if nearGarage and nearDist <= Config.MarkerDistance then
            wait = 0  -- per-frame while close: draw marker, read keys

            local m = Config.Marker[nearGarage.type] or Config.Marker.personal
            DrawMarker(m.type, nearGarage.coords.x, nearGarage.coords.y, nearGarage.coords.z - 1.0,
                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                m.size.x, m.size.y, m.size.z,
                m.color.r, m.color.g, m.color.b, m.color.a,
                false, true, 2, false, nil, nil, false)

            if nearDist <= Config.InteractDistance then
                local veh = GetVehiclePedIsIn(ped, false)

                if nearGarage.type == 'impound' then
                    -- Impound lots only reclaim (on foot). No storing here.
                    helpText(Config.Messages.impound_prompt)
                    if IsControlJustReleased(0, E) then
                        TriggerServerEvent('garage-pro:requestImpoundList', nearIndex)
                    end
                elseif veh ~= 0 then
                    -- In a vehicle at a personal/job garage -> store it.
                    helpText(Config.Messages.store_prompt)
                    if IsControlJustReleased(0, E) then
                        TriggerServerEvent('garage-pro:store', NetworkGetNetworkIdFromEntity(veh), nearIndex)
                    end
                else
                    -- On foot at a personal/job garage -> open the list.
                    helpText(Config.Messages.retrieve_prompt)
                    if IsControlJustReleased(0, E) then
                        TriggerServerEvent('garage-pro:requestList', nearIndex)
                    end
                end
            end
        end

        Wait(wait)
    end
end)

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, blip in ipairs(blips) do
        RemoveBlip(blip)
    end
    ClearPedTasks(PlayerPedId())  -- in case the fob anim was mid-play
end)
