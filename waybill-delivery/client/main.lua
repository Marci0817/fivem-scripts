--[[ waybill-delivery :: client/main.lua

     Presentation + requests only. The client draws blips/markers/help text, runs
     the timed packing/unloading/signature animations with a cancel guard, seats
     the driver in the server-spawned truck, and mirrors the server's waybill
     state into the overlay widget. It never decides money, stock or eligibility.

     Interaction idiom copied from products/garage: one permanent thread, variable
     waits (1000ms idle / 0ms engaged), native marker + help text, no custom menu.
     The overlay widget is display-only — no SetNuiFocus anywhere in this file. ]]

local E = 38  -- INPUT_PICKUP ([E] by default)

local function dbg(...)
    if Config.Debug then print('[waybill]', ...) end
end

--------------------------------------------------------------------------------
-- Client-side mirror of the server's authoritative state
--------------------------------------------------------------------------------

local onDuty        = false
local activeWaybill = nil   -- table pushed by the server, or nil
local truckNetId    = nil
local seatedNetId   = nil   -- so we only warp into the truck once
local deadlineTimer = 0     -- GetGameTimer() value when the run expires

local peds  = { clocker = nil, dispatcher = nil, clerk = nil }
local blips = { depot = nil, dest = nil }
local facedPed = nil        -- avoid re-tasking the same NPC every frame

--------------------------------------------------------------------------------
-- Native UI helpers
--------------------------------------------------------------------------------

local function helpText(msg)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function drawMarker(coords)
    local m = Config.Marker
    DrawMarker(m.type, coords.x, coords.y, coords.z - 0.95,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        m.size.x, m.size.y, m.size.z,
        m.color.r, m.color.g, m.color.b, m.color.a,
        false, true, 2, false, nil, nil, false)
end

local function drawText3D(coords, text)
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 215)
    SetTextEntry('STRING')
    SetTextCentre(true)
    AddTextComponentString(text)
    SetDrawOrigin(coords.x, coords.y, coords.z + 0.9, 0)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

local function playSound(s)
    PlaySoundFrontend(-1, s.name, s.set, true)
end

--------------------------------------------------------------------------------
-- Overlay widget (display-only SendNUIMessage pushes — never any focus)
--------------------------------------------------------------------------------

local function timeRemaining()
    if not activeWaybill then return 0 end
    return math.max(0, math.floor((deadlineTimer - GetGameTimer()) / 1000))
end

local function pushNui()
    local visible = activeWaybill ~= nil
    local payload = { type = 'waybillDisplay', visible = visible }
    if visible then
        local d = activeWaybill.destination
        payload.waybill = {
            id            = activeWaybill.id,
            clientName    = activeWaybill.clientName,
            status        = activeWaybill.status,
            basePayout    = activeWaybill.basePayout,
            timeLimit     = activeWaybill.timeLimit,
            timeRemaining = timeRemaining(),
            items         = activeWaybill.items,  -- { {label, qty, packed}, ... }
            destination   = {
                label  = d.label,
                coords = { x = d.coords.x, y = d.coords.y, z = d.coords.z },
            },
        }
    end
    SendNUIMessage(payload)
end

-- Tick the countdown into the widget once a second while a run is live.
CreateThread(function()
    while true do
        Wait(1000)
        if activeWaybill then pushNui() end
    end
end)

--------------------------------------------------------------------------------
-- Peds, blips, destination management
--------------------------------------------------------------------------------

local function spawnPed(model, x, y, z, heading)
    local hash = joaat(model)
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 100 do Wait(10); tries = tries + 1 end
    if not HasModelLoaded(hash) then dbg('ped model failed to load', model); return nil end

    local ped = CreatePed(4, hash, x, y, z - 1.0, heading, false, true)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetModelAsNoLongerNeeded(hash)
    return ped
end

local function addBlip(coords, sprite, color, scale, label, route)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, sprite)
    SetBlipColour(blip, color)
    SetBlipScale(blip, scale)
    SetBlipAsShortRange(blip, not route)
    if route then SetBlipRoute(blip, true) end
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
    return blip
end

-- Spawn / clear the destination clerk + route blip to match the active waybill.
local function refreshDestination()
    if activeWaybill and activeWaybill.destination then
        local d = activeWaybill.destination
        if not blips.dest then
            blips.dest = addBlip(d.coords, Config.Blip.sprite, Config.Blip.color,
                Config.Blip.scale, Config.Blip.destinationLabel, true)
            playSound(Config.Sound.waypoint)
        end
        if not peds.clerk then
            local def = Config.DeliveryDestinations[d.index or 0]
            local heading = def and def.clerkPed and def.clerkPed.heading or 0.0
            local model = def and def.clerkPed and def.clerkPed.model or 's_m_m_trucker_01'
            peds.clerk = spawnPed(model, d.coords.x, d.coords.y, d.coords.z, heading)
        end
    else
        if blips.dest then RemoveBlip(blips.dest); blips.dest = nil end
        if peds.clerk then DeletePed(peds.clerk); peds.clerk = nil end
    end
end

--------------------------------------------------------------------------------
-- Timed action: looped anim + cancel guard (move / damage / death aborts)
--------------------------------------------------------------------------------

local function attachProps(ped, list)
    local objs = {}
    for _, p in ipairs(list) do
        local hash = joaat(p.model)
        RequestModel(hash)
        local tries = 0
        while not HasModelLoaded(hash) and tries < 50 do Wait(10); tries = tries + 1 end
        if HasModelLoaded(hash) then
            local obj = CreateObject(hash, 0.0, 0.0, 0.0, true, true, false)
            AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, p.bone),
                p.pos.x, p.pos.y, p.pos.z, p.rot.x, p.rot.y, p.rot.z,
                true, true, false, true, 1, true)
            objs[#objs + 1] = obj
            SetModelAsNoLongerNeeded(hash)
        end
    end
    return objs
end

local function doTimedAction(anim, durationSec, props)
    local ped         = PlayerPedId()
    local startCoords = GetEntityCoords(ped)
    local startHealth = GetEntityHealth(ped)

    RequestAnimDict(anim.dict)
    local tries = 0
    while not HasAnimDictLoaded(anim.dict) and tries < 100 do Wait(10); tries = tries + 1 end
    TaskPlayAnim(ped, anim.dict, anim.name, 8.0, -8.0, -1, 1, 0.0, false, false, false)

    local objs   = props and attachProps(ped, props) or {}
    local endTime = GetGameTimer() + (durationSec * 1000)
    local ok      = true
    local lastPct = -1  -- track last displayed percentage to avoid redundant updates

    while GetGameTimer() < endTime do
        Wait(0)
        local pct = math.floor(100 - ((endTime - GetGameTimer()) / (durationSec * 1000) * 100))
        if pct ~= lastPct then
            helpText(Config.Messages.busy:format(pct))
            lastPct = pct
        end
        if #(GetEntityCoords(ped) - startCoords) > 3.0
        or IsEntityDead(ped)
        or GetEntityHealth(ped) < startHealth then
            ok = false; break
        end
    end

    ClearPedTasks(ped)
    RemoveAnimDict(anim.dict)
    for _, o in ipairs(objs) do DetachEntity(o, true, true); DeleteObject(o) end

    if ok then playSound(Config.Sound.step)
    else playSound(Config.Sound.error); Bridge.Notify(Config.Messages.action_cancelled, 'inform') end
    return ok
end

--------------------------------------------------------------------------------
-- Server -> client
--------------------------------------------------------------------------------

RegisterNetEvent('waybill:notify', function(msg, kind)
    Bridge.Notify(msg, kind)
end)

RegisterNetEvent('waybill:sync', function(data)
    onDuty        = data.onDuty and true or false
    activeWaybill = data.waybill
    truckNetId    = data.truckNetId

    if activeWaybill then
        deadlineTimer = GetGameTimer() + ((activeWaybill.timeRemaining or activeWaybill.timeLimit) * 1000)
    end
    if not truckNetId then seatedNetId = nil end

    refreshDestination()
    pushNui()
end)

-- Seat the driver once the server-spawned truck streams in (garage pattern).
CreateThread(function()
    while true do
        if truckNetId and truckNetId ~= seatedNetId then
            Wait(50)  -- faster check when waiting for truck to stream
            local n = 0
            while not NetworkDoesEntityExistWithNetworkId(truckNetId) and n < 80 do Wait(25); n = n + 1 end
            if NetworkDoesEntityExistWithNetworkId(truckNetId) then
                local veh = NetworkGetEntityFromNetworkId(truckNetId)
                SetPedIntoVehicle(PlayerPedId(), veh, -1)
                seatedNetId = truckNetId
            end
        else
            Wait(1000)  -- idle when no truck pending
        end
    end
end)

--------------------------------------------------------------------------------
-- Active interaction points, derived from the current state
--------------------------------------------------------------------------------

local M = Config.Messages

local function faceOnce(ped)
    if ped and facedPed ~= ped then
        TaskTurnPedToFaceEntity(ped, PlayerPedId(), 2000)
        facedPed = ped
    end
end

-- Returns the list of points the player can act on right now. Only relevant
-- markers are ever drawn, which keeps the yard readable.
local function activePoints()
    local pts = {}
    local wb  = activeWaybill

    -- Clock in / out at the shift office.
    if not onDuty then
        pts[#pts + 1] = {
            coords = Config.Depot.clockerPed.coords, ped = peds.clocker, label = M.label_clocker,
            prompt = M.prompt_clock_in:format(Config.VehicleDeposit),
            action = function() TriggerServerEvent('waybill:clockIn') end,
        }
    elseif not wb then
        pts[#pts + 1] = {
            coords = Config.Depot.clockerPed.coords, ped = peds.clocker, label = M.label_clocker,
            prompt = M.prompt_clock_out,
            action = function() TriggerServerEvent('waybill:clockOut') end,
        }
        -- Dispatcher hands out a waybill when you have none.
        pts[#pts + 1] = {
            coords = Config.Depot.dispatcherPed.coords, ped = peds.dispatcher, label = M.label_dispatcher,
            prompt = M.prompt_dispatcher,
            action = function() TriggerServerEvent('waybill:requestWaybill') end,
        }
    end

    if wb then
        if wb.status == 'assigned' then
            for _, st in ipairs(Config.PackingStations) do
                pts[#pts + 1] = {
                    coords = st.coords, label = M.label_pack, prompt = M.prompt_pack,
                    action = function()
                        if doTimedAction(Config.Anim.pack, Config.PackingDuration) then
                            TriggerServerEvent('waybill:finishPacking')
                        end
                    end,
                }
            end
        elseif wb.status == 'packed' then
            pts[#pts + 1] = {
                coords = Config.Depot.truckSpawn, label = M.label_load, prompt = M.prompt_load,
                action = function() TriggerServerEvent('waybill:loadTruck') end,
            }
        elseif wb.status == 'loaded' then
            pts[#pts + 1] = {
                coords = wb.destination.coords, label = M.label_unload, prompt = M.prompt_unload,
                action = function()
                    if doTimedAction(Config.Anim.unload, Config.UnloadingDuration) then
                        TriggerServerEvent('waybill:finishUnloading')
                    end
                end,
            }
        elseif wb.status == 'delivered' then
            pts[#pts + 1] = {
                coords = wb.destination.coords, ped = peds.clerk, label = M.label_signature,
                prompt = M.prompt_signature,
                action = function()
                    if doTimedAction(Config.Anim.signature, Config.SignatureDuration, Config.SignatureProps) then
                        TriggerServerEvent('waybill:getSignature')
                    end
                end,
            }
        elseif wb.status == 'confirmed' then
            pts[#pts + 1] = {
                coords = Config.Depot.truckReturn, label = M.label_return, prompt = M.prompt_return,
                action = function() TriggerServerEvent('waybill:returnTruck') end,
            }
        end
    end

    return pts
end

--------------------------------------------------------------------------------
-- Main loop: nearest active point -> marker + label + [E]
--------------------------------------------------------------------------------

CreateThread(function()
    while true do
        local wait = 1000
        local pos  = GetEntityCoords(PlayerPedId())

        local best, bestDist
        for _, p in ipairs(activePoints()) do
            local d = #(pos - vector3(p.coords.x, p.coords.y, p.coords.z))
            if not bestDist or d < bestDist then best, bestDist = p, d end
        end

        if best and bestDist <= Config.MarkerDistance then
            wait = 0
            drawMarker(best.coords)
            drawText3D(best.coords, best.label)

            if bestDist <= Config.InteractDistance then
                faceOnce(best.ped)
                helpText(best.prompt)
                if IsControlJustReleased(0, E) then best.action() end
            elseif facedPed then
                facedPed = nil
            end
        elseif facedPed then
            facedPed = nil
        end

        Wait(wait)
    end
end)

--------------------------------------------------------------------------------
-- Static setup: depot blip + the two depot NPCs
--------------------------------------------------------------------------------

CreateThread(function()
    blips.depot = addBlip(Config.Depot.coords, Config.Blip.sprite, Config.Blip.color,
        Config.Blip.scale, Config.Blip.depotLabel, false)

    local c = Config.Depot.clockerPed
    peds.clocker = spawnPed(c.model, c.coords.x, c.coords.y, c.coords.z, c.coords.w)
    local d = Config.Depot.dispatcherPed
    peds.dispatcher = spawnPed(d.model, d.coords.x, d.coords.y, d.coords.z, d.coords.w)
end)

--------------------------------------------------------------------------------
-- Cleanup: blips, peds, NUI, anim tasks
--------------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    SendNUIMessage({ type = 'waybillDisplay', visible = false })
    if blips.depot then RemoveBlip(blips.depot) end
    if blips.dest then RemoveBlip(blips.dest) end
    for _, ped in pairs(peds) do
        if ped and DoesEntityExist(ped) then DeletePed(ped) end
    end
    ClearPedTasks(PlayerPedId())
end)
