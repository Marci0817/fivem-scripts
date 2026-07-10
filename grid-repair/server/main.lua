--[[ grid-repair :: server/main.lua
     Server-authoritative electrician gig.

     The server owns ALL state and decisions:
       - which power boxes are failed and WHEN they failed (age drives payout),
       - the fuse-sequence the client must match (generated here, validated here),
       - money in/out via Bridge.* only (never a raw framework object).

     Outage state is ephemeral in-memory — it is world state, not player data,
     so there is no SQL. It resets on resource restart, by design. ]]

local function dbg(...)
    if Config.Debug then print('[grid-repair]', ...) end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- outages[index] = {
--   failed   = bool,
--   failedAt = os.time(),         -- epoch seconds; payout scales with age
--   lock     = nil | { src, seq, startedMs },  -- set while a player is repairing
-- }
local outages = {}

local retryUntil = {} -- [src] = GetGameTimer() value the player may next start a repair
local failStreak = {} -- [src] = consecutive failed attempts (drives SINK 2 surcharge)

for i = 1, #Config.Locations do
    outages[i] = { failed = false, failedAt = 0, lock = nil }
end

--------------------------------------------------------------------------------
-- Outage helpers
--------------------------------------------------------------------------------

local function activeCount()
    local n = 0
    for _, o in ipairs(outages) do
        if o.failed then n = n + 1 end
    end
    return n
end

-- Trip a specific box (server-authoritative) and tell every client to light it up.
local function tripBox(index)
    local o = outages[index]
    if not o or o.failed then return end
    o.failed   = true
    o.failedAt = os.time()
    o.lock     = nil
    TriggerClientEvent('grid-repair:outageStarted', -1, index)
    TriggerClientEvent('grid-repair:notify', -1,
        Config.Messages.new_outage:format(Config.Locations[index].label), 'inform')
    dbg('tripped box', index, Config.Locations[index].label)
end

-- Pick a random currently-working box and trip it, if any exist.
local function tripRandomBox()
    local candidates = {}
    for i, o in ipairs(outages) do
        if not o.failed then candidates[#candidates + 1] = i end
    end
    if #candidates == 0 then return end
    tripBox(candidates[math.random(#candidates)])
end

-- Clear a box back to working and tell every client to remove blip/marker/FX.
local function clearBox(index)
    local o = outages[index]
    if not o then return end
    o.failed = false
    o.lock   = nil
    TriggerClientEvent('grid-repair:outageCleared', -1, index)
    dbg('cleared box', index)
end

--------------------------------------------------------------------------------
-- Scheduler — randomized interval, respects Config.Outage.maxActive
--------------------------------------------------------------------------------

CreateThread(function()
    math.randomseed(os.time())

    -- Seed a few outages so the map is not empty on a fresh start.
    for _ = 1, math.min(Config.Outage.startFailed, #Config.Locations) do
        tripRandomBox()
    end

    while true do
        Wait(math.random(Config.Outage.intervalMin, Config.Outage.intervalMax))
        if activeCount() < Config.Outage.maxActive then
            tripRandomBox()
        end
    end
end)

--------------------------------------------------------------------------------
-- Sync — a joining client asks which boxes are currently failed
--------------------------------------------------------------------------------

RegisterNetEvent('grid-repair:requestSync', function()
    local src = source
    local failed = {}
    for i, o in ipairs(outages) do
        if o.failed then failed[#failed + 1] = i end
    end
    TriggerClientEvent('grid-repair:sync', src, failed)
end)

--------------------------------------------------------------------------------
-- Start a repair — charge the fuse kit, lock the box, hand the client a sequence
--------------------------------------------------------------------------------

local function withinRange(src, index)
    local ped = GetPlayerPed(src)
    if ped == 0 then return false end
    local pcoords = GetEntityCoords(ped)
    local d = #(pcoords - Config.Locations[index].coords)
    return d <= (Config.Interact.interactDistance + 2.0) -- small tolerance vs. client
end

RegisterNetEvent('grid-repair:startRepair', function(index)
    local src = source
    index = tonumber(index)
    if not index or not outages[index] then return end

    local o = outages[index]

    -- Validate the world state the client claims to see.
    if not o.failed then
        TriggerClientEvent('grid-repair:notify', src, Config.Messages.not_failed, 'error')
        return
    end
    if o.lock then
        TriggerClientEvent('grid-repair:notify', src, Config.Messages.already_working, 'warning')
        return
    end
    if not withinRange(src, index) then
        TriggerClientEvent('grid-repair:notify', src, Config.Messages.too_far, 'error')
        return
    end

    -- Retry cooldown (part of SINK 2 — a failed attempt locks you out briefly).
    local now = GetGameTimer()
    if retryUntil[src] and now < retryUntil[src] then
        local left = math.ceil((retryUntil[src] - now) / 1000)
        TriggerClientEvent('grid-repair:notify', src, Config.Messages.on_cooldown:format(left), 'warning')
        return
    end

    -- SINK 1 — charge the fuse kit up front; honor the atomic boolean.
    if not Bridge.RemoveMoney(src, Config.FuseKitCost, Config.Account) then
        TriggerClientEvent('grid-repair:notify', src, Config.Messages.no_kit:format(Config.FuseKitCost), 'error')
        return
    end

    -- Generate the authoritative sequence and lock the box to this player.
    local seq = {}
    for _ = 1, Config.Minigame.sequenceLength do
        seq[#seq + 1] = math.random(1, Config.Minigame.fuseCount)
    end
    o.lock = { src = src, seq = seq, startedMs = now }

    dbg('startRepair', src, 'box', index, 'seq', table.concat(seq, ','))

    TriggerClientEvent('grid-repair:beginMinigame', src, index, {
        sequence  = seq,
        fuseCount = Config.Minigame.fuseCount,
        timeLimit = Config.Minigame.timeLimit,
    })
end)

--------------------------------------------------------------------------------
-- Finish a repair — validate the entered sequence, then pay or penalize
--------------------------------------------------------------------------------

-- outcome: 'success' | 'fail' | 'timeout' | 'cancel' (client's claim)
RegisterNetEvent('grid-repair:finishRepair', function(index, outcome, entered)
    local src = source
    index = tonumber(index)
    if not index or not outages[index] then return end

    local o = outages[index]
    local lock = o.lock
    -- Only the player who holds the lock may resolve it.
    if not lock or lock.src ~= src then return end

    -- The client hands back what it entered; the server decides success by
    -- comparing to the sequence IT generated and by checking its own elapsed
    -- clock — client-reported timing is never trusted.
    local elapsed = GetGameTimer() - lock.startedMs
    local ok = (outcome == 'success')

    if ok and type(entered) == 'table' then
        if #entered ~= #lock.seq or elapsed > Config.Minigame.timeLimit then
            ok = false
        else
            for i = 1, #lock.seq do
                if tonumber(entered[i]) ~= lock.seq[i] then ok = false; break end
            end
        end
    else
        ok = false
    end

    o.lock = nil -- release the box either way

    if ok then
        -- Age-scaled payout: reward driving to a neglected/far-away outage.
        local age   = os.time() - o.failedAt
        local bonus = math.min(age * Config.PayoutPerSecond, Config.MaxAgeBonus)
        local pay   = math.floor(Config.BasePayout + bonus)

        if Config.RepeatFail.resetOnPass then failStreak[src] = 0 end
        Bridge.AddMoney(src, pay, Config.Account)
        clearBox(index)

        TriggerClientEvent('grid-repair:repairResult', src, true)
        TriggerClientEvent('grid-repair:notify', src, Config.Messages.success:format(pay), 'success')
        dbg('repair OK', src, 'box', index, 'age', age, 'pay', pay)
        return
    end

    -- Failure path. Box stays broken. The kit fee was already consumed unless
    -- the owner enabled refunds.
    if Config.RefundOnFail then
        Bridge.AddMoney(src, Config.FuseKitCost, Config.Account)
    end

    -- SINK 2 — repeated-failure surcharge + retry cooldown.
    if outcome ~= 'cancel' then
        failStreak[src] = (failStreak[src] or 0) + 1
        retryUntil[src] = GetGameTimer() + Config.RetryCooldown

        if failStreak[src] >= Config.RepeatFail.threshold and Config.RepeatFail.surcharge > 0 then
            if Bridge.RemoveMoney(src, Config.RepeatFail.surcharge, Config.Account) then
                TriggerClientEvent('grid-repair:notify', src,
                    Config.Messages.surcharge:format(Config.RepeatFail.surcharge), 'warning')
            end
        end
    end

    local msgKey = (outcome == 'timeout' and 'timeout')
                or (outcome == 'cancel'  and 'cancelled')
                or 'failed'
    TriggerClientEvent('grid-repair:repairResult', src, false)
    TriggerClientEvent('grid-repair:notify', src, Config.Messages[msgKey], 'error')
    dbg('repair FAIL', src, 'box', index, 'outcome', outcome)
end)

--------------------------------------------------------------------------------
-- Cleanup — release any lock a dropping player held, forget their session state
--------------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local src = source
    for i, o in ipairs(outages) do
        if o.lock and o.lock.src == src then
            o.lock = nil
            dbg('released lock on box', i, 'for dropped', src)
        end
    end
    retryUntil[src] = nil
    failStreak[src] = nil
end)

--------------------------------------------------------------------------------
-- Public admin helper — /gridfail forces an outage (testing / events)
--------------------------------------------------------------------------------

RegisterCommand('gridfail', function(src)
    if src ~= 0 then return end -- console only
    tripRandomBox()
end, true)
