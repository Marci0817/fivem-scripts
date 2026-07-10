--[[
    garage-pro :: server/main.lua

    All decisions live here: ownership, job access, money, spawning and the
    automatic impound sweep. The client only ever sends a request and typed
    input (a plate, a garage index, a network id) — never an outcome.

    The ONLY framework touch-points are Bridge.* calls:
        Bridge.GetIdentifier(src)      -> who owns the vehicle row
        Bridge.GetJob(src)             -> job-garage access + fee exemption
        Bridge.RemoveMoney / AddMoney  -> charge / refund fees (atomic)

    Player-facing feedback is always pushed to the client with
    TriggerClientEvent('garage-pro:notify', ...) -> Bridge.Notify runs there;
    Bridge.Notify is client-only and must never be called server-side.

    Vehicles are created SERVER-SIDE with CreateVehicleServerSetter — the reliable
    OneSync path. The client only ever receives a network id; a forged client
    entity handle can never reach this file. This mirrors products/garage/server.lua.
]]

local function dbg(...)
    if Config.Debug then print('[garage-pro]', ...) end
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

-- Per-player request cooldown (anti-spam). Cleared on disconnect.
local lastAction = {}

-- plate -> GetGameTimer() when last seen with a driver (impound sweep bookkeeping).
-- Declared here so store/reclaim can clear a plate's entry the moment it leaves
-- the world, keeping the table from growing unbounded on a long-running server.
local lastSeen = {}

local function onCooldown(src)
    local now  = GetGameTimer()
    local last = lastAction[src]
    if last and (now - last) < Config.Cooldown then
        return true
    end
    lastAction[src] = now
    return false
end

AddEventHandler('playerDropped', function()
    lastAction[source] = nil
end)

-- Distance check: the player must actually be standing at the garage they claim.
-- Returns the matching garage config or nil. GetPlayerPed works under OneSync.
local function garageNear(src, garageIndex)
    local garage = Config.Garages[garageIndex]
    if not garage then return nil end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end

    local dist = #(GetEntityCoords(ped) - garage.coords)
    if dist > (Config.InteractDistance + 5.0) then  -- +slack for lag/animation
        dbg(('player %d is %.1fm from garage %d'):format(src, dist, garageIndex))
        return nil
    end
    return garage
end

-- True if this player may use this garage at all (job garages are job-gated).
local function canUseGarage(src, garage)
    if garage.type == 'job' then
        return Bridge.GetJob(src).name == garage.job
    end
    return true
end

-- Trim GTA's trailing plate padding.
local function cleanPlate(plate)
    return (plate or ''):gsub('%s+$', '')
end

-- 8-char A–Z0–9 plate, matching the in-game plate width.
local PLATE_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
local function randomPlate()
    local out = {}
    for i = 1, 8 do
        local n = math.random(#PLATE_CHARS)
        out[i] = PLATE_CHARS:sub(n, n)
    end
    return table.concat(out)
end

-- CreateVehicleServerSetter wants a model hash. Rows store either a model name
-- ('sultan') or a numeric hash string (fleet vehicles seen by hash on store).
local function modelHash(model)
    return tonumber(model) or joaat(model)
end

--------------------------------------------------------------------------------
-- Database (oxmysql, parameterized — never string-concat input into SQL)
--------------------------------------------------------------------------------

local function getRowByPlate(plate)
    return MySQL.single.await(
        'SELECT owner, plate, model, vehtype, stored, garage_location, impound_location ' ..
        'FROM owned_vehicles WHERE plate = ?',
        { plate })
end

-- Vehicles stored at a specific personal garage for this owner.
local function listPersonalStored(owner, garageIndex)
    return MySQL.query.await(
        'SELECT plate, model FROM owned_vehicles ' ..
        'WHERE owner = ? AND stored = 1 AND garage_location = ?',
        { owner, garageIndex }) or {}
end

-- Shared fleet stored at a specific job garage (visible to every job member).
local function listJobStored(job, garageIndex)
    return MySQL.query.await(
        'SELECT plate, model FROM owned_vehicles ' ..
        'WHERE owner = ? AND stored = 1 AND garage_location = ?',
        { 'job:' .. job, garageIndex }) or {}
end

-- This owner's impounded vehicles.
local function listImpounded(owner)
    return MySQL.query.await(
        'SELECT plate, model FROM owned_vehicles ' ..
        "WHERE owner = ? AND impound_location = 'impound'",
        { owner }) or {}
end

local function upsertStored(owner, plate, model, vehtype, garageIndex)
    MySQL.insert.await(
        'INSERT INTO owned_vehicles (owner, plate, model, vehtype, stored, garage_location, impound_location) ' ..
        'VALUES (?, ?, ?, ?, 1, ?, NULL) ' ..
        'ON DUPLICATE KEY UPDATE stored = 1, garage_location = ?, impound_location = NULL',
        { owner, plate, model, vehtype, garageIndex, garageIndex })
end

local function markOut(plate)
    MySQL.update.await(
        'UPDATE owned_vehicles SET stored = 0 WHERE plate = ?',
        { plate })
end

local function markReclaimed(plate)
    MySQL.update.await(
        'UPDATE owned_vehicles SET stored = 0, impound_location = NULL WHERE plate = ?',
        { plate })
end

--------------------------------------------------------------------------------
-- Server-side spawn helper. Returns netId on success, nil on failure.
--------------------------------------------------------------------------------

local function spawnVehicle(garage, model, vehtype, plate)
    local s   = garage.spawn
    local veh = CreateVehicleServerSetter(modelHash(model), vehtype or 'automobile', s.x, s.y, s.z, s.w)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return nil
    end
    SetVehicleNumberPlateText(veh, plate)
    return NetworkGetNetworkIdFromEntity(veh)
end

--------------------------------------------------------------------------------
-- Store  (client sends the netId of the vehicle it is sitting in)
--------------------------------------------------------------------------------

RegisterNetEvent('garage-pro:store', function(netId, garageIndex)
    local src = source
    if type(netId) ~= 'number' or type(garageIndex) ~= 'number' then return end

    local garage = garageNear(src, garageIndex)
    if not garage or garage.type == 'impound' then return end
    if not canUseGarage(src, garage) then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.store_own_only, 'error')
        return
    end

    -- Resolve the entity from the network id ON THE SERVER. A forged/garbage id
    -- simply resolves to nothing.
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    local owner = Bridge.GetIdentifier(src)
    if not owner then return end

    local plate = cleanPlate(GetVehicleNumberPlateText(veh))
    local row   = getRowByPlate(plate)

    if garage.type == 'job' then
        -- Fleet: any job member may store any fleet vehicle. Row is keyed to the
        -- job, not the individual, so any member can pull it back out.
        if row and row.owner ~= ('job:' .. garage.job) and row.owner ~= owner then
            TriggerClientEvent('garage-pro:notify', src, Config.Messages.store_own_only, 'error')
            return
        end
        if row and row.stored == 1 then
            TriggerClientEvent('garage-pro:notify', src, Config.Messages.store_already, 'error')
            return
        end
        -- Fleet-adoption guard: a plate with NO owned_vehicles row would be minted
        -- as a brand-new free fleet vehicle. Off by default so a member cannot
        -- launder an ownerless street car into the free fleet.
        if not row and not Config.AllowJobFleetAdoption then
            TriggerClientEvent('garage-pro:notify', src, Config.Messages.store_not_fleet, 'error')
            return
        end
        local model   = row and row.model   or tostring(GetEntityModel(veh))
        local vehtype = row and row.vehtype or (GetVehicleType(veh) or 'automobile')
        upsertStored('job:' .. garage.job, plate, model, vehtype, garageIndex)
    else
        -- Personal: the plate must map to a row THIS player owns.
        if not row or row.owner ~= owner then
            TriggerClientEvent('garage-pro:notify', src, Config.Messages.store_own_only, 'error')
            return
        end
        if row.stored == 1 then
            TriggerClientEvent('garage-pro:notify', src, Config.Messages.store_already, 'error')
            return
        end
        upsertStored(owner, plate, row.model, row.vehtype, garageIndex)
    end

    DeleteEntity(veh)  -- server-side delete is authoritative
    lastSeen[plate] = nil  -- left the world: drop its impound-sweep bookkeeping
    TriggerClientEvent('garage-pro:notify', src, Config.Messages.store_success, 'success')
    dbg(('%s stored %s at garage %d'):format(owner, plate, garageIndex))
end)

--------------------------------------------------------------------------------
-- Request lists  (client opens a menu; server returns only eligible vehicles)
--------------------------------------------------------------------------------

RegisterNetEvent('garage-pro:requestList', function(garageIndex)
    local src = source
    if type(garageIndex) ~= 'number' then return end

    local garage = garageNear(src, garageIndex)
    if not garage or garage.type == 'impound' then return end
    if not canUseGarage(src, garage) then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.not_nearby, 'error')
        return
    end

    local owner = Bridge.GetIdentifier(src)
    if not owner then return end

    local vehicles
    if garage.type == 'job' then
        vehicles = listJobStored(garage.job, garageIndex)
    else
        vehicles = listPersonalStored(owner, garageIndex)
    end

    TriggerClientEvent('garage-pro:openList', src, garageIndex, 'retrieve', vehicles)
end)

RegisterNetEvent('garage-pro:requestImpoundList', function(garageIndex)
    local src = source
    if type(garageIndex) ~= 'number' then return end

    local garage = garageNear(src, garageIndex)
    if not garage or garage.type ~= 'impound' then return end

    local owner = Bridge.GetIdentifier(src)
    if not owner then return end

    TriggerClientEvent('garage-pro:openList', src, garageIndex, 'reclaim', listImpounded(owner))
end)

--------------------------------------------------------------------------------
-- Retrieve  (spawn a stored vehicle for the retrieve fee)
--------------------------------------------------------------------------------

RegisterNetEvent('garage-pro:retrieve', function(plate, garageIndex)
    local src = source
    if type(plate) ~= 'string' or #plate == 0 or #plate > 8 then return end
    if type(garageIndex) ~= 'number' then return end
    if onCooldown(src) then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.on_cooldown, 'error')
        return
    end

    local garage = garageNear(src, garageIndex)
    if not garage or garage.type == 'impound' then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.not_nearby, 'error')
        return
    end
    if not canUseGarage(src, garage) then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.not_nearby, 'error')
        return
    end

    local owner = Bridge.GetIdentifier(src)
    if not owner then return end

    -- Ownership + "actually stored here" re-validation (never trust the menu).
    local row = getRowByPlate(plate)
    if not row then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.retrieve_not_owned, 'error')
        return
    end

    local isJobVehicle = garage.type == 'job' and row.owner == ('job:' .. garage.job)
    local isOwn        = row.owner == owner
    if not (isOwn or isJobVehicle) then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.retrieve_not_owned, 'error')
        return
    end
    if row.stored ~= 1 or row.garage_location ~= garageIndex then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.retrieve_not_stored, 'error')
        return
    end

    -- Charge the fee unless this job retrieves for free.
    local free = Config.FreeForJobs[Bridge.GetJob(src).name] == true
    if not free and Config.RetrieveFee > 0 then
        if not Bridge.RemoveMoney(src, Config.RetrieveFee, Config.FeeAccount) then
            TriggerClientEvent('garage-pro:notify', src,
                Config.Messages.retrieve_insufficient:format(Config.RetrieveFee), 'error')
            return
        end
    end

    local netId = spawnVehicle(garage, row.model, row.vehtype, plate)
    if not netId then
        if not free and Config.RetrieveFee > 0 then
            Bridge.AddMoney(src, Config.RetrieveFee, Config.FeeAccount)  -- never take money for nothing
        end
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.retrieve_spawn_failed, 'error')
        dbg(('spawn failed model=%s for %s'):format(row.model, owner))
        return
    end

    markOut(plate)
    TriggerClientEvent('garage-pro:vehicleSpawned', src, netId)
    if free then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.retrieve_success_free, 'success')
    else
        TriggerClientEvent('garage-pro:notify', src,
            Config.Messages.retrieve_success_paid:format(Config.RetrieveFee), 'success', 'money')
    end
    dbg(('%s retrieved %s free=%s'):format(owner, plate, tostring(free)))
end)

--------------------------------------------------------------------------------
-- Reclaim  (pull a vehicle out of impound for the impound + tow fee together)
--------------------------------------------------------------------------------

RegisterNetEvent('garage-pro:reclaim', function(plate, garageIndex)
    local src = source
    if type(plate) ~= 'string' or #plate == 0 or #plate > 8 then return end
    if type(garageIndex) ~= 'number' then return end
    if onCooldown(src) then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.on_cooldown, 'error')
        return
    end

    local garage = garageNear(src, garageIndex)
    if not garage or garage.type ~= 'impound' then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.not_nearby, 'error')
        return
    end

    local owner = Bridge.GetIdentifier(src)
    if not owner then return end

    local row = getRowByPlate(plate)
    if not row or row.owner ~= owner or row.impound_location ~= 'impound' then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.impound_not_found, 'error')
        return
    end

    -- Impound is a penalty: no job exemption, fees charged together, atomically.
    local total = Config.ImpoundFee + Config.TowFee
    if total > 0 then
        if not Bridge.RemoveMoney(src, total, Config.FeeAccount) then
            TriggerClientEvent('garage-pro:notify', src,
                Config.Messages.reclaim_insufficient:format(total), 'error')
            return
        end
    end

    local netId = spawnVehicle(garage, row.model, row.vehtype, plate)
    if not netId then
        if total > 0 then
            Bridge.AddMoney(src, total, Config.FeeAccount)  -- refund on spawn failure
        end
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.reclaim_spawn_failed, 'error')
        dbg(('reclaim spawn failed model=%s for %s'):format(row.model, owner))
        return
    end

    markReclaimed(plate)
    lastSeen[cleanPlate(plate)] = nil  -- fresh from impound: reset sweep bookkeeping
    TriggerClientEvent('garage-pro:fobClick', src)  -- flavour anim client-side
    TriggerClientEvent('garage-pro:vehicleSpawned', src, netId)
    TriggerClientEvent('garage-pro:notify', src,
        Config.Messages.reclaim_success:format(total), 'success', 'money')
    dbg(('%s reclaimed %s (-$%d)'):format(owner, plate, total))
end)

--------------------------------------------------------------------------------
-- Automatic impound sweep
--   Every Config.ImpoundCheckInterval we scan world vehicles whose plate maps
--   to an OUT owned row (stored=0, not already impounded). A vehicle whose
--   driver seat has been empty for Config.AbandonedVehicleTimer is towed.
--------------------------------------------------------------------------------

local function impoundVehicle(veh, row, plate)
    local coords = GetEntityCoords(veh)
    DeleteEntity(veh)
    MySQL.update.await(
        "UPDATE owned_vehicles SET stored = 0, impound_location = 'impound', impounded_at = NOW() " ..
        'WHERE plate = ?',
        { row.plate })
    lastSeen[plate] = nil

    TriggerEvent('garageProImpound:alert', {
        plate    = row.plate,
        owner_id = row.owner,
        coords   = coords,
        fee      = Config.ImpoundFee + Config.TowFee,
    })
    dbg(('impounded %s (owner %s)'):format(row.plate, row.owner))
end

CreateThread(function()
    while true do
        Wait(Config.ImpoundCheckInterval)

        -- Build a plate -> row lookup of everything currently OUT in the world.
        local rows = MySQL.query.await(
            'SELECT owner, plate, model, vehtype FROM owned_vehicles ' ..
            'WHERE stored = 0 AND impound_location IS NULL') or {}
        if #rows > 0 then
            local outByPlate = {}
            for _, r in ipairs(rows) do outByPlate[cleanPlate(r.plate)] = r end

            local now = GetGameTimer()
            for _, veh in ipairs(GetAllVehicles()) do
                local plate = cleanPlate(GetVehicleNumberPlateText(veh))
                local row = outByPlate[plate]
                if row then
                    local driver = GetPedInVehicleSeat(veh, -1)
                    if driver ~= 0 and DoesEntityExist(driver) then
                        lastSeen[plate] = now  -- occupied: reset the clock
                    else
                        local since = lastSeen[plate]
                        if not since then
                            lastSeen[plate] = now
                        elseif (now - since) >= Config.AbandonedVehicleTimer
                            and math.random(1, 100) <= Config.ImpoundChance then
                            impoundVehicle(veh, row, plate)
                        end
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Impound alert  (public event — other resources may listen or replace it)
--   Payload: { plate, owner_id, coords, fee }
--------------------------------------------------------------------------------

AddEventHandler('garageProImpound:alert', function(data)
    if not Config.ImpoundAlertEnabled then return end

    local police = {}
    for _, job in ipairs(Config.PoliceJobNames) do police[job] = true end

    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        if police[Bridge.GetJob(src).name] then
            local message = ('%s — %s'):format(
                Config.Messages.impound_alert_title,
                Config.Messages.impound_alert_text:format(data.plate))
            TriggerClientEvent('garage-pro:notify', src, message, 'inform')
        end
    end
end)

--------------------------------------------------------------------------------
-- Test/admin: seed a vehicle so QA has something to store/retrieve.
--   /givecar [model]      (defaults to 'sultan')
-- ACE-gated per security best-practices.
--   In server.cfg:  add_ace group.admin command.givecar allow
--------------------------------------------------------------------------------

RegisterCommand('givecar', function(src, args)
    if src ~= 0 and not IsPlayerAceAllowed(src, 'command.givecar') then
        TriggerClientEvent('garage-pro:notify', src, Config.Messages.no_permission, 'error')
        return
    end
    if src == 0 then
        print('[garage-pro] /givecar must be run by a player (it needs an owner id).')
        return
    end

    local model = (args[1] and args[1]:lower()) or 'sultan'
    local owner = Bridge.GetIdentifier(src)
    if not owner then return end

    local plate = randomPlate()
    MySQL.insert.await(
        'INSERT INTO owned_vehicles (owner, plate, model, vehtype, stored, garage_location) ' ..
        'VALUES (?, ?, ?, ?, 1, 1)',
        { owner, plate, model, 'automobile' })

    TriggerClientEvent('garage-pro:notify', src,
        Config.Messages.givecar_added:format(model, plate), 'success')
end, false)

--------------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(res)
    if GetCurrentResourceName() ~= res then return end
    print(('[garage-pro] ready on framework: %s'):format(Bridge.GetFramework()))
end)
