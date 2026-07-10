--[[ waybill-delivery :: server/main.lua

     Server-authoritative delivery state machine. The client only REQUESTS a
     stage transition; the server re-checks distance, the waybill's current
     status and warehouse stock/truck existence before it advances anything or
     moves money. The only framework touch-points are Bridge.* calls.

     One waybill per player at a time. Everything is in memory — a resource
     restart wipes active waybills and resets Config.Stock (see DEVNOTES.md). ]]

local function dbg(...)
    if Config.Debug then print('[waybill]', ...) end
end

--------------------------------------------------------------------------------
-- Session state
--------------------------------------------------------------------------------

local nextWaybillId = 1        -- session-unique, auto-incremented
local waybills = {}            -- [identifier] = waybill struct (the core data object)
local duty     = {}            -- [identifier] = { src, depositHeld, onDuty }
local idBySrc  = {}            -- [src] = identifier  (so playerDropped can find state)

local function idOf(src)
    return idBySrc[src]
end

local function notify(src, msg, kind)
    TriggerClientEvent('waybill:notify', src, msg, kind)
end

--------------------------------------------------------------------------------
-- Distance validation (never trust the client's claim of "I'm here")
--------------------------------------------------------------------------------

-- +slack absorbs animation drift / OneSync lag; still far too tight to teleport-cheat.
local function nearCoords(src, coords, slack)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local d = #(GetEntityCoords(ped) - vector3(coords.x, coords.y, coords.z))
    return d <= (Config.InteractDistance + (slack or 5.0))
end

local function nearAnyPackingStation(src)
    for _, st in ipairs(Config.PackingStations) do
        if nearCoords(src, st.coords) then return true end
    end
    return false
end

-- Resolve the player's work truck from the stored net id, ON THE SERVER.
local function truckEntity(wb)
    if not wb or not wb.vehicleNetId then return nil end
    local veh = NetworkGetEntityFromNetworkId(wb.vehicleNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    return veh
end

--------------------------------------------------------------------------------
-- Client sync — pushed after every state change. Shapes the NUI payload too.
--------------------------------------------------------------------------------

local function waybillForClient(wb)
    if not wb then return nil end
    local items = {}
    for i, it in ipairs(wb.items) do
        items[i] = { label = it.label, qty = it.qty, packed = it.packed }
    end
    return {
        id            = wb.id,
        clientName    = wb.clientName,
        status        = wb.status,
        items         = items,
        basePayout    = wb.basePayout,
        timeLimit     = wb.timeLimit,
        timeRemaining = math.max(0, wb.timeLimit - (os.time() - wb.createdAt)),
        isIllegal     = wb.isIllegal,
        destination   = {
            label  = wb.destination.label,
            coords = wb.destination.coords,
            index  = wb.destination.index,
        },
    }
end

local function sync(src)
    local id  = idOf(src)
    local d   = id and duty[id]
    local wb  = id and waybills[id]
    TriggerClientEvent('waybill:sync', src, {
        onDuty     = d ~= nil and d.onDuty or false,
        waybill    = waybillForClient(wb),
        truckNetId = wb and wb.vehicleNetId or nil,
    })
end

--------------------------------------------------------------------------------
-- Manifest assignment
--------------------------------------------------------------------------------

-- Split templates so we can honour Config.Illegal without scanning every roll.
local legalManifests, illegalManifests = {}, {}
for _, m in ipairs(Config.AvailableWaybills) do
    if m.isIllegal then illegalManifests[#illegalManifests + 1] = m
    else legalManifests[#legalManifests + 1] = m end
end

local function pickManifest()
    -- Illegal runs only exist when the server owner allows them, and then only
    -- about half the time (risk/reward variance).
    local pool = legalManifests
    if Config.Illegal and #illegalManifests > 0 and math.random() < 0.5 then
        pool = illegalManifests
    end
    if #pool == 0 then pool = legalManifests end
    if #pool == 0 then return nil end
    return pool[math.random(#pool)]
end

local function buildWaybill(id, manifest)
    local dest = Config.DeliveryDestinations[math.random(#Config.DeliveryDestinations)]
    local base = (manifest.distance == 'long') and Config.LongRoutePayout or Config.ShortRoutePayout

    local items = {}
    for i, it in ipairs(manifest.items) do
        items[i] = { name = it.name, label = it.label, qty = it.qty, packed = 0 }
    end

    return {
        id          = id,
        assignedTo  = nil,  -- filled by caller
        status      = 'assigned',
        items       = items,
        destination = {
            index    = 0,  -- filled below
            coords   = vector3(dest.coords.x, dest.coords.y, dest.coords.z),
            label    = dest.label,
            clerkPed = dest.clerkPed and dest.clerkPed.model or nil,
        },
        clientName        = manifest.clientName,
        isIllegal         = manifest.isIllegal == true,
        basePayout        = base,
        packingCost       = Config.PackingMaterialsCost,  -- record only; charged up-front
        lateDeliveryPenalty = 0,
        netPayout         = 0,
        timeLimit         = Config.DeliveryTimeLimit,
        createdAt   = os.time(), packedAt = nil, loadedAt = nil,
        deliveredAt = nil, confirmedAt = nil,
        vehicleNetId = nil, vehicleSpawned = false,
    }
end

--------------------------------------------------------------------------------
-- Clock in / out  (deposit sink)
--------------------------------------------------------------------------------

RegisterNetEvent('waybill:clockIn', function()
    local src = source
    if not nearCoords(src, Config.Depot.clockerPed.coords) then return end

    local id = Bridge.GetIdentifier(src)
    if not id then return end

    -- Job gate.
    if Config.AllowedJobs ~= nil then
        local job = Bridge.GetJob(src)
        if not (job and Config.AllowedJobs[job.name]) then
            notify(src, Config.Messages.not_allowed, 'error'); return
        end
    end

    if duty[id] and duty[id].onDuty then
        notify(src, Config.Messages.already_clocked_in, 'error'); return
    end

    -- Reserve the duty slot BEFORE the (possibly-yielding) money call. On
    -- standalone Bridge.RemoveMoney awaits an oxmysql query; reserving first
    -- means a rapid second clock-in fails the guard above and can't double-charge
    -- the deposit (same TOCTOU pattern as returnTruck). Rolled back on failure.
    idBySrc[src] = id
    duty[id] = { src = src, depositHeld = 0, onDuty = true }

    -- Post the truck deposit atomically — deny the shift if they can't cover it.
    if not Bridge.RemoveMoney(src, Config.VehicleDeposit, Config.Account) then
        duty[id] = nil
        idBySrc[src] = nil
        notify(src, Config.Messages.need_deposit:format(Config.VehicleDeposit), 'error'); return
    end

    duty[id].depositHeld = Config.VehicleDeposit
    notify(src, Config.Messages.clocked_in:format(Config.VehicleDeposit), 'success')
    sync(src)
    dbg(('%s clocked in'):format(id))
end)

RegisterNetEvent('waybill:clockOut', function()
    local src = source
    local id  = idOf(src)
    if not (id and duty[id] and duty[id].onDuty) then
        notify(src, Config.Messages.not_clocked_in, 'error'); return
    end
    if not nearCoords(src, Config.Depot.clockerPed.coords) then return end
    if waybills[id] then
        notify(src, Config.Messages.finish_first, 'error'); return
    end

    -- Any deposit still held (they clocked in but never completed a run) comes back.
    if duty[id].depositHeld > 0 then
        Bridge.AddMoney(src, duty[id].depositHeld, Config.Account)
    end
    duty[id] = nil
    idBySrc[src] = nil
    notify(src, Config.Messages.clocked_out, 'success')
    sync(src)
    dbg(('%s clocked out'):format(id))
end)

--------------------------------------------------------------------------------
-- Request a waybill  (packing-materials sink)
--------------------------------------------------------------------------------

RegisterNetEvent('waybill:requestWaybill', function()
    local src = source
    local id  = idOf(src)
    if not (id and duty[id] and duty[id].onDuty) then
        notify(src, Config.Messages.not_clocked_in, 'error'); return
    end
    if not nearCoords(src, Config.Depot.dispatcherPed.coords) then return end
    if waybills[id] then
        notify(src, Config.Messages.already_have, 'error'); return
    end
    -- One deposit per run: after a completed return depositHeld is 0, so a fresh
    -- clock-in is required before another waybill.
    if duty[id].depositHeld <= 0 then
        notify(src, Config.Messages.not_clocked_in, 'error'); return
    end

    -- Reserve the waybill slot with a sentinel BEFORE the (possibly-yielding)
    -- charge, so a rapid second request fails the `waybills[id]` guard above and
    -- can't double-charge packing materials on standalone. The 'reserving' status
    -- is rejected by every stage guard (finishPacking/loadTruck/etc. all check for
    -- their own status), so a stray event in this window is a no-op. Cleared on
    -- failure; overwritten by the real struct on success.
    waybills[id] = { status = 'reserving', items = {} }

    -- Charge packing materials atomically (the up-front sink).
    if not Bridge.RemoveMoney(src, Config.PackingMaterialsCost, Config.Account) then
        waybills[id] = nil
        notify(src, Config.Messages.need_materials:format(Config.PackingMaterialsCost), 'error'); return
    end

    local manifest = pickManifest()
    if not manifest then waybills[id] = nil; return end

    local wb = buildWaybill(nextWaybillId, manifest)
    wb.assignedTo = id
    -- Re-resolve the destination index for the client (buildWaybill picked one).
    for i, d in ipairs(Config.DeliveryDestinations) do
        if d.label == wb.destination.label then wb.destination.index = i break end
    end
    nextWaybillId = nextWaybillId + 1

    waybills[id] = wb
    notify(src, Config.Messages.waybill_assigned:format(wb.id, wb.clientName), 'success')
    sync(src)
    dbg(('%s assigned waybill #%d (%s, illegal=%s)'):format(id, wb.id, wb.clientName, tostring(wb.isIllegal)))
end)

--------------------------------------------------------------------------------
-- Packing  (stock sink — decremented atomically on completion only)
--------------------------------------------------------------------------------

RegisterNetEvent('waybill:finishPacking', function()
    local src = source
    local id  = idOf(src)
    local wb  = id and waybills[id]
    if not wb or wb.status ~= 'assigned' then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end
    if not nearAnyPackingStation(src) then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end

    -- Every line item must be in stock, or nothing is touched.
    for _, it in ipairs(wb.items) do
        if (Config.Stock[it.name] or 0) < it.qty then
            notify(src, Config.Messages.out_of_stock, 'error'); return
        end
    end
    -- Atomic decrement + mark packed.
    for _, it in ipairs(wb.items) do
        Config.Stock[it.name] = Config.Stock[it.name] - it.qty
        it.packed = it.qty
    end
    wb.status = 'packed'
    wb.packedAt = os.time()
    notify(src, Config.Messages.packing_done, 'success')
    sync(src)
    dbg(('%s packed waybill #%d'):format(id, wb.id))
end)

--------------------------------------------------------------------------------
-- Load the truck  (spawns the work vehicle server-side)
--------------------------------------------------------------------------------

RegisterNetEvent('waybill:loadTruck', function()
    local src = source
    local id  = idOf(src)
    local wb  = id and waybills[id]
    if not wb or wb.status ~= 'packed' then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end
    if not nearCoords(src, Config.Depot.truckSpawn) then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end

    local s   = Config.Depot.truckSpawn
    local veh = CreateVehicleServerSetter(joaat(Config.TruckModel), 'automobile', s.x, s.y, s.z, s.w)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        notify(src, Config.Messages.spawn_failed, 'error')
        dbg(('truck spawn failed for %s'):format(id))
        return
    end

    wb.vehicleNetId   = NetworkGetNetworkIdFromEntity(veh)
    wb.vehicleSpawned = true
    wb.status         = 'loaded'
    wb.loadedAt       = os.time()
    notify(src, Config.Messages.truck_loaded:format(wb.destination.label), 'success')
    sync(src)
    dbg(('%s loaded truck for waybill #%d'):format(id, wb.id))
end)

--------------------------------------------------------------------------------
-- Unload at the destination  (one-way sink of the packed goods)
--------------------------------------------------------------------------------

RegisterNetEvent('waybill:finishUnloading', function()
    local src = source
    local id  = idOf(src)
    local wb  = id and waybills[id]
    if not wb or wb.status ~= 'loaded' then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end
    if not nearCoords(src, wb.destination.coords) then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end
    -- The truck has to actually be here with the goods.
    local veh = truckEntity(wb)
    if not veh or #(GetEntityCoords(veh) - wb.destination.coords) > 30.0 then
        notify(src, Config.Messages.truck_missing, 'error'); return
    end

    wb.status = 'delivered'
    wb.deliveredAt = os.time()
    notify(src, Config.Messages.unloaded, 'success')
    sync(src)
    dbg(('%s unloaded waybill #%d'):format(id, wb.id))
end)

--------------------------------------------------------------------------------
-- Clerk signature = proof of delivery (fires the public hooks)
--------------------------------------------------------------------------------

RegisterNetEvent('waybill:getSignature', function()
    local src = source
    local id  = idOf(src)
    local wb  = id and waybills[id]
    if not wb or wb.status ~= 'delivered' then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end
    if not nearCoords(src, wb.destination.coords) then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end

    wb.status = 'confirmed'
    wb.confirmedAt = os.time()

    -- Public "proof of delivery" event — other resources hook this. Payload is
    -- documented in DEVNOTES.md and must keep this exact shape.
    TriggerEvent('waybill:deliveryConfirmed', {
        playerId    = src,
        waybillId   = wb.id,
        destination = wb.destination.label,
        basePayout  = wb.basePayout,
        isIllegal   = wb.isIllegal,
    })
    if wb.isIllegal then
        TriggerEvent('waybill:policeAlert', {
            coords    = wb.destination.coords,
            waybillId = wb.id,
        })
    end

    notify(src, Config.Messages.signed, 'success')
    sync(src)
    dbg(('%s got signature for waybill #%d'):format(id, wb.id))
end)

--------------------------------------------------------------------------------
-- Return the truck  (payout + deposit refund + shift ends)
--------------------------------------------------------------------------------

RegisterNetEvent('waybill:returnTruck', function()
    local src = source
    local id  = idOf(src)
    local wb  = id and waybills[id]
    if not wb or wb.status ~= 'confirmed' then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end
    if not nearCoords(src, Config.Depot.truckReturn) then
        notify(src, Config.Messages.wrong_stage, 'error'); return
    end

    -- Despawn the work truck (authoritative server-side delete).
    local veh = truckEntity(wb)
    if veh then DeleteEntity(veh) end

    -- Late penalty if the run blew the time limit.
    local late = (os.time() - wb.createdAt) > wb.timeLimit
    wb.lateDeliveryPenalty = late and Config.LateDeliveryPenalty or 0

    -- Packing materials were already paid at the dispatcher, so they are NOT
    -- subtracted again here (see DEVNOTES.md — one packing sink, up-front).
    local net = wb.basePayout - wb.lateDeliveryPenalty
    if wb.isIllegal then net = math.floor(net * Config.IllegalPayoutMultiplier) end
    net = math.max(0, net)
    wb.netPayout = net

    -- Capture the payout figures, then CLEAR authoritative state BEFORE any
    -- Bridge money call. On standalone the money path awaits an oxmysql query
    -- (yields the coroutine); clearing first means a rapid second
    -- waybill:returnTruck fails the `wb.status ~= 'confirmed'` / `id and duty[id]`
    -- guards before the first payout resolves — no double reward (TOCTOU close).
    local refund   = duty[id] and duty[id].depositHeld or 0
    local waybillId = wb.id
    wb.status = 'returned'          -- neuter any stale in-memory reference
    if duty[id] then duty[id].depositHeld = 0; duty[id].onDuty = false end
    waybills[id] = nil
    duty[id] = nil
    idBySrc[src] = nil

    -- Money moves only after state is gone, using the captured locals.
    Bridge.AddMoney(src, net, Config.Account)
    if refund > 0 then Bridge.AddMoney(src, refund, Config.Account) end

    if late then notify(src, Config.Messages.late_notice:format(Config.LateDeliveryPenalty), 'error') end
    notify(src, Config.Messages.payout_summary:format(net, refund), 'success')

    sync(src)
    dbg(('%s returned truck for waybill #%d, paid $%d (+$%d deposit)'):format(id, waybillId, net, refund))
end)

--------------------------------------------------------------------------------
-- Disconnect: forfeit the deposit, despawn the truck, wipe state
--------------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local src = source
    local id  = idOf(src)
    if not id then return end

    local wb = waybills[id]
    if wb then
        local veh = truckEntity(wb)
        if veh then DeleteEntity(veh) end
    end
    -- Deposit is NOT refunded on disconnect while on duty (forfeited).
    waybills[id] = nil
    duty[id] = nil
    idBySrc[src] = nil
    dbg(('%s dropped — deposit forfeited, truck despawned'):format(id))
end)

--------------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(res)
    if GetCurrentResourceName() ~= res then return end
    print(('[waybill] ready on framework: %s'):format(Bridge.GetFramework()))
end)
