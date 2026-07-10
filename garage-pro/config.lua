--[[
    garage-pro :: config.lua  (shared)

    Everything tunable lives here. There is NOT a single framework reference in
    this whole resource — money, identity and notifications all go through
    Bridge.*, so this exact code runs on ESX, QBCore, Qbox or standalone.

    garage-pro extends the single-garage products/garage example into three
    garage TYPES (personal / job / impound) plus an automatic impound arc.
]]

Config = {}

Config.Debug = false            -- true prints [garage-pro] traces to the console

--------------------------------------------------------------------------------
-- Economy (two sinks only — storage tax / insurance are deferred to v1.1)
--------------------------------------------------------------------------------

Config.RetrieveFee = 250        -- $ to pull a stored vehicle out of a garage
Config.ImpoundFee  = 250        -- $ penalty to reclaim an impounded vehicle
Config.TowFee      = 50         -- $ tow charge, added on top of the impound fee
Config.FeeAccount  = 'cash'     -- account the fees are drawn from ('cash' | 'bank')

-- Jobs that retrieve their vehicles for FREE (Bridge.GetJob().name is the key).
-- Impound reclaim is a penalty and is never exempt.
Config.FreeForJobs = {
    police    = true,
    ambulance = true,
    mechanic  = true,
}

-- Job garages: may a job member store an OWNERLESS world vehicle (one with no
-- owned_vehicles row) to mint it as a new free fleet vehicle? Default false —
-- otherwise a member could drive any unowned street car into the garage and add
-- it to the free fleet. When false, only pre-seeded / admin-added (/givecar)
-- fleet rows live in job garages.
Config.AllowJobFleetAdoption = false

--------------------------------------------------------------------------------
-- Interaction distances / timing
--------------------------------------------------------------------------------

Config.MarkerDistance   = 15.0  -- m: draw the marker / poll faster inside this
Config.InteractDistance = 3.0   -- m: must be this close to press [E]
Config.Cooldown         = 2000  -- ms: per-player anti-spam between requests

--------------------------------------------------------------------------------
-- Impound sweep (automatic, no player action)
--------------------------------------------------------------------------------

Config.ImpoundCheckInterval  = 30000     -- ms: how often the sweep runs (~30s granularity)
Config.AbandonedVehicleTimer = 1800000   -- ms: unattended-out time before impound (30 min)
Config.ImpoundChance         = 100       -- %: chance an eligible vehicle is impounded per sweep
Config.ImpoundAlertEnabled   = true      -- notify on-duty police when a vehicle is impounded
Config.PoliceJobNames        = { 'police', 'sheriff' }  -- jobs that receive impound alerts

--------------------------------------------------------------------------------
-- Map blips (one per garage; sprite/colour picked by garage type)
--------------------------------------------------------------------------------

Config.Blip = {
    personal = { sprite = 357, color = 3, scale = 0.9, label = 'Garage' },
    job      = { sprite = 357, color = 1, scale = 0.9, label = 'Job Garage' },
    impound  = { sprite = 227, color = 1, scale = 0.9, label = 'Impound Lot' },
}

--------------------------------------------------------------------------------
-- Ground markers (drawn when nearby; type/size/colour picked by garage type)
--------------------------------------------------------------------------------

Config.Marker = {
    personal = { type = 36, size = vector3(1.5, 1.5, 1.5), color = { r = 65,  g = 145, b = 255, a = 150 } },
    job      = { type = 36, size = vector3(2.0, 2.0, 1.5), color = { r = 255, g = 0,   b = 0,   a = 150 } },
    impound  = { type = 36, size = vector3(2.0, 2.0, 1.5), color = { r = 255, g = 100, b = 0,   a = 150 } },
}

--------------------------------------------------------------------------------
-- Garages
--   type   = 'personal' | 'job' | 'impound'
--   label  = shown on the blip / debug
--   coords = vector3 of the marker + interaction point
--   spawn  = vector4 (x, y, z, heading) where a retrieved vehicle appears
--   job    = REQUIRED for type='job' — the Bridge.GetJob().name that may use it
--------------------------------------------------------------------------------

Config.Garages = {
    -- Personal garages (any player, their own vehicles) ------------------------
    {
        type   = 'personal',
        label  = 'Legion Square',
        coords = vector3(215.9, -809.9, 30.7),
        spawn  = vector4(222.3, -796.3, 30.6, 245.0),
    },
    {
        type   = 'personal',
        label  = 'Sandy Shores',
        coords = vector3(1737.9, 3710.4, 34.2),
        spawn  = vector4(1729.6, 3708.5, 34.2, 25.0),
    },

    -- Job garage (shared fleet for the matching job) ---------------------------
    {
        type   = 'job',
        label  = 'Mission Row PD Motor Pool',
        job    = 'police',
        coords = vector3(454.6, -1017.4, 28.4),
        spawn  = vector4(438.6, -1018.3, 28.6, 90.0),
    },

    -- Impound lot (reclaim impounded vehicles here) ----------------------------
    {
        type   = 'impound',
        label  = 'Davis Impound',
        coords = vector3(407.7, -1622.6, 29.3),
        spawn  = vector4(400.9, -1630.5, 29.3, 230.0),
    },
}

--------------------------------------------------------------------------------
-- Messages — ALL player-facing text (English). Logic references keys only.
--   %s / %d placeholders are filled in code; keep the order documented inline.
--------------------------------------------------------------------------------

Config.Messages = {
    -- Store -------------------------------------------------------------------
    store_prompt        = 'Press ~INPUT_PICKUP~ to store this vehicle',
    store_success       = 'Vehicle stored.',
    store_own_only      = 'You can only store your own vehicle here.',
    store_already       = 'That vehicle is already stored.',
    store_not_fleet     = 'That vehicle is not part of this fleet.',

    -- Retrieve ----------------------------------------------------------------
    retrieve_prompt         = 'Press ~INPUT_PICKUP~ to open the garage',
    retrieve_no_vehicles    = 'You have no vehicles stored here.',
    retrieve_not_stored     = 'That vehicle is not in this garage.',
    retrieve_not_owned      = 'That is not your vehicle.',
    retrieve_insufficient   = 'You need $%d to retrieve this vehicle.',        -- 1: fee
    retrieve_success_paid   = 'Vehicle retrieved (-$%d).',                     -- 1: fee
    retrieve_success_free   = 'Vehicle retrieved (on duty — free).',
    retrieve_spawn_failed   = 'Could not spawn the vehicle. You were refunded.',
    retrieve_at_garage      = 'Your vehicles (use /retrieve <plate>):',
    retrieve_no_pending     = 'Open a garage first, then /retrieve <plate>.',
    option_take_out         = 'In garage — click to take out',       -- ox_lib option (retrieve)
    option_reclaim          = 'Impounded — click to reclaim',         -- ox_lib option (impound)
    chat_header             = 'garage-pro',                           -- chat fallback list header

    -- Impound alert (to police) -----------------------------------------------
    impound_alert_title = 'Vehicle Impounded',
    impound_alert_text  = 'Plate %s was towed to the impound lot.',           -- 1: plate

    -- Impound reclaim ---------------------------------------------------------
    impound_prompt       = 'Press ~INPUT_PICKUP~ to open the impound lot',
    impound_no_vehicles  = 'You have no impounded vehicles.',
    impound_not_found    = 'That vehicle is not in the impound lot.',
    reclaim_prompt       = 'Your impounded vehicles (use /retrieve <plate>):',
    reclaim_insufficient = 'You need $%d to reclaim this vehicle.',           -- 1: total
    reclaim_success      = 'Vehicle reclaimed (-$%d).',                       -- 1: total
    reclaim_spawn_failed = 'Could not spawn the vehicle. You were refunded.',
    reclaim_at_impound   = 'Reclaim your impounded vehicles here.',

    -- Shared ------------------------------------------------------------------
    not_nearby  = 'You are not at the garage.',
    on_cooldown = 'Please wait a moment before trying again.',

    -- Admin / test ------------------------------------------------------------
    no_permission = 'No permission.',
    givecar_added = 'Added %s (plate %s) to your Legion Square garage.',  -- 1: model, 2: plate
}
