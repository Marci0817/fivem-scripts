--[[ grid-repair :: client/main.lua
     Presentation + requests only. The client shows outages, prompts [E], runs
     the fuse-sequence overlay, and RELAYS the result to the server. It never
     decides success or payout — the server does (server/main.lua).

     Interaction idiom, message table and cleanup rules: docs/agentic/STYLE_GUIDE.md
     (reference implementation: products/garage). ]]

local function dbg(...)
    if Config.Debug then print('[grid-repair]', ...) end
end

--------------------------------------------------------------------------------
-- Outage state (mirror of the server's, kept in sync by net events)
--------------------------------------------------------------------------------

local failed   = {} -- [index] = true while the box is broken
local blips    = {} -- [index] = blip handle
local fxHandles = {} -- [index] = looped-ptfx handle

-- Minigame runtime handles, so every exit path can tear them down.
local minigame = {
    active   = false,
    index    = nil,
    prop     = nil,
    animDict = nil,
}

--------------------------------------------------------------------------------
-- Help text (native)
--------------------------------------------------------------------------------

local function helpText(msg)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

--------------------------------------------------------------------------------
-- Failed-box visuals: blip + looped electric-crackle particle
--------------------------------------------------------------------------------

local function addOutageVisuals(index)
    local loc = Config.Locations[index]
    if not loc then return end

    if not blips[index] then
        local b = AddBlipForCoord(loc.coords.x, loc.coords.y, loc.coords.z)
        SetBlipSprite(b, Config.Blip.sprite)
        SetBlipColour(b, Config.Blip.color)
        SetBlipScale(b, Config.Blip.scale)
        SetBlipAsShortRange(b, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(Config.Blip.label)
        EndTextCommandSetBlipName(b)
        blips[index] = b
    end

    if not fxHandles[index] then
        local p = Config.Ptfx
        RequestNamedPtfxAsset(p.asset)
        local tries = 0
        while not HasNamedPtfxAssetLoaded(p.asset) and tries < 100 do
            Wait(10); tries = tries + 1
        end
        if HasNamedPtfxAssetLoaded(p.asset) then
            UseParticleFxAssetNextCall(p.asset)
            fxHandles[index] = StartParticleFxLoopedAtCoord(p.effect,
                loc.coords.x, loc.coords.y, loc.coords.z + p.zOffset,
                0.0, 0.0, 0.0, p.scale, false, false, false, false)
        end
    end
end

local function removeOutageVisuals(index)
    if blips[index] then RemoveBlip(blips[index]); blips[index] = nil end
    if fxHandles[index] then StopParticleFxLooped(fxHandles[index], false); fxHandles[index] = nil end
end

--------------------------------------------------------------------------------
-- Sync from server
--------------------------------------------------------------------------------

RegisterNetEvent('grid-repair:sync', function(list)
    -- Rebuild from scratch: clear anything stale, then apply the server's truth.
    for i in pairs(failed) do failed[i] = nil end
    for i in pairs(blips) do removeOutageVisuals(i) end
    for _, i in ipairs(list) do
        failed[i] = true
        addOutageVisuals(i)
    end
end)

RegisterNetEvent('grid-repair:outageStarted', function(index)
    failed[index] = true
    addOutageVisuals(index)
end)

RegisterNetEvent('grid-repair:outageCleared', function(index)
    failed[index] = nil
    removeOutageVisuals(index)
end)

RegisterNetEvent('grid-repair:notify', function(msg, kind)
    Bridge.Notify(msg, kind)
end)

-- Ask the server for current outages once we're spawned in.
CreateThread(function()
    Wait(1500)
    TriggerServerEvent('grid-repair:requestSync')
end)

--------------------------------------------------------------------------------
-- Immersion: repair anim + handheld tool, torn down together
--------------------------------------------------------------------------------

local function startRepairAnim()
    local ped = PlayerPedId()

    RequestAnimDict(Config.Anim.dict)
    local tries = 0
    while not HasAnimDictLoaded(Config.Anim.dict) and tries < 100 do
        Wait(10); tries = tries + 1
    end
    if HasAnimDictLoaded(Config.Anim.dict) then
        -- flag 49 = upper-body loop, player keeps control (we lock movement via focus)
        TaskPlayAnim(ped, Config.Anim.dict, Config.Anim.name, 8.0, -8.0, -1, 49, 0, false, false, false)
        minigame.animDict = Config.Anim.dict
    end

    local model = joaat(Config.Prop.model)
    RequestModel(model)
    tries = 0
    while not HasModelLoaded(model) and tries < 100 do
        Wait(10); tries = tries + 1
    end
    if HasModelLoaded(model) then
        local coords = GetEntityCoords(ped)
        local obj = CreateObject(model, coords.x, coords.y, coords.z, true, true, true)
        AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, Config.Prop.bone),
            Config.Prop.offset.x, Config.Prop.offset.y, Config.Prop.offset.z,
            Config.Prop.rot.x, Config.Prop.rot.y, Config.Prop.rot.z,
            true, true, false, true, 1, true)
        minigame.prop = obj
        SetModelAsNoLongerNeeded(model)
    end
end

local function stopRepairAnim()
    local ped = PlayerPedId()
    ClearPedTasks(ped)
    if minigame.animDict then
        RemoveAnimDict(minigame.animDict)
        minigame.animDict = nil
    end
    if minigame.prop then
        DeleteEntity(minigame.prop)
        minigame.prop = nil
    end
end

--------------------------------------------------------------------------------
-- Minigame overlay (ONE compact NUI widget — built by the nui-developer next)
--
--  NUI CONTRACT
--  Lua -> NUI  SendNUIMessage({
--                action    = 'startFuseGame',
--                sequence  = { int, ... },   -- correct order to press (1..fuseCount)
--                fuseCount = int,            -- how many fuse buttons to render
--                timeLimit = int,            -- ms; widget shows a countdown bar
--              })
--  Lua -> NUI  SendNUIMessage({ action = 'endFuseGame' })  -- force-close (death/stop)
--  NUI -> Lua  RegisterNUICallback('fuseResult', {
--                success = bool,
--                entered = { int, ... },     -- the order the player pressed
--              })  -- fired on completion OR timeout (timeout => success=false, entered={})
--  NUI -> Lua  RegisterNUICallback('fuseCancel', {})       -- player backed out (Esc)
--
--  SetNuiFocus(true, true) is required here because the widget is CLICKED, not
--  typed into — the player needs a cursor. Focus is released on EVERY exit path
--  below (result, cancel, timeout, death, disconnect, resource stop).
--------------------------------------------------------------------------------

local function endMinigame()
    if not minigame.active then return end
    minigame.active = false
    minigame.index  = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'endFuseGame' })
    stopRepairAnim()
end

RegisterNetEvent('grid-repair:beginMinigame', function(index, data)
    if minigame.active then return end
    minigame.active = true
    minigame.index  = index

    Bridge.Notify(Config.Messages.started, 'inform')
    startRepairAnim()

    SetNuiFocus(true, true) -- cursor for clicking the fuses; released in endMinigame()
    SendNUIMessage({
        action    = 'startFuseGame',
        sequence  = data.sequence,
        fuseCount = data.fuseCount,
        timeLimit = data.timeLimit,
    })

    -- Watchdog: if the player dies while the widget is up, abort cleanly.
    CreateThread(function()
        while minigame.active do
            if IsEntityDead(PlayerPedId()) then
                local idx = minigame.index
                endMinigame()
                TriggerServerEvent('grid-repair:finishRepair', idx, 'cancel', {})
                break
            end
            Wait(250)
        end
    end)
end)

-- The nui-developer's widget reports the outcome here.
RegisterNUICallback('fuseResult', function(data, cb)
    local idx = minigame.index
    local success = data and data.success == true
    local entered = (data and type(data.entered) == 'table') and data.entered or {}
    endMinigame()
    if idx then
        local outcome = success and 'success' or 'fail'
        TriggerServerEvent('grid-repair:finishRepair', idx, outcome, entered)
    end
    cb('ok')
end)

RegisterNUICallback('fuseCancel', function(_, cb)
    local idx = minigame.index
    endMinigame()
    if idx then
        TriggerServerEvent('grid-repair:finishRepair', idx, 'cancel', {})
    end
    cb('ok')
end)

-- Local success/fail hook + outcome sound. Other client resources can also
-- listen to 'grid-repair:repairResult' (see DEVNOTES "Events other resources...").
RegisterNetEvent('grid-repair:repairResult', function(ok)
    if ok then
        PlaySoundFrontend(-1, Config.Sounds.success.name, Config.Sounds.success.set, true)
        PlaySoundFrontend(-1, Config.Sounds.payout.name, Config.Sounds.payout.set, true)
    else
        PlaySoundFrontend(-1, Config.Sounds.fail.name, Config.Sounds.fail.set, true)
    end
end)

--------------------------------------------------------------------------------
-- Main loop: marker + [E] on the nearest FAILED box (variable-wait, 0ms engaged)
--------------------------------------------------------------------------------

CreateThread(function()
    while true do
        local wait = 1000

        if not minigame.active and next(failed) then
            local ped = PlayerPedId()
            local pos = GetEntityCoords(ped)

            local nearIndex, nearDist
            for i in pairs(failed) do
                local d = #(pos - Config.Locations[i].coords)
                if not nearDist or d < nearDist then
                    nearDist, nearIndex = d, i
                end
            end

            if nearIndex and nearDist <= Config.Interact.markerDistance then
                wait = 0
                local loc = Config.Locations[nearIndex]
                local m = Config.Marker
                DrawMarker(m.type, loc.coords.x, loc.coords.y, loc.coords.z - 1.0,
                    0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    m.size.x, m.size.y, m.size.z,
                    m.color.r, m.color.g, m.color.b, m.color.a,
                    false, true, 2, false, nil, nil, false)

                if nearDist <= Config.Interact.interactDistance then
                    helpText(Config.Messages.prompt_repair)
                    if IsControlJustReleased(0, Config.Interact.key) then
                        TriggerServerEvent('grid-repair:startRepair', nearIndex)
                    end
                end
            end
        end

        Wait(wait)
    end
end)

--------------------------------------------------------------------------------
-- Cleanup: blips, particles, minigame focus/anim/prop on resource stop
--------------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    endMinigame()
    for i in pairs(blips) do removeOutageVisuals(i) end
end)
