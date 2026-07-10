--[[ waybill-delivery :: config.lua  (shared)

     EVERYTHING tunable lives here. There is not one framework reference in this
     resource — money, identity and job all go through Bridge.*, so the same code
     runs on ESX / QBCore / Qbox / standalone.

     The loop this configures:
        clock in (post a truck deposit) -> ask the dispatcher for a waybill
        -> pack the items -> load the truck -> drive to the destination
        -> unload -> get the clerk's signature (proof of delivery)
        -> drive back and return the truck -> get paid + deposit back.

     Coordinates below are working examples around the Cypress Flats warehouse;
     move them to suit your map (the ground Z may need a small nudge per spot). ]]

Config = {}

Config.Debug = false  -- prints [waybill] trace lines to the console

--------------------------------------------------------------------------------
-- Access + faction hooks
--------------------------------------------------------------------------------

-- Who may clock in. nil = anyone. Otherwise a set of job names checked against
-- Bridge.GetJob(src).name, e.g. { trucker = true, offroad = true }.
Config.AllowedJobs = nil

-- Master switch for contraband runs. When false, only legal manifests are ever
-- assigned. When true, each assignment rolls ~50/50 between a legal manifest and
-- an isIllegal one (illegal manifests are NEVER assigned while this is false).
Config.Illegal = true

-- Illegal net payouts are multiplied by this (risk premium).
Config.IllegalPayoutMultiplier = 1.5

--------------------------------------------------------------------------------
-- Economy (all sinks are server-enforced through Bridge.RemoveMoney)
--------------------------------------------------------------------------------

Config.Account = 'cash'  -- which account moves; bridge maps it per framework

Config.VehicleDeposit       = 500  -- $ bond posted at clock-in, returned on truck return
Config.PackingMaterialsCost = 50   -- $ charged up-front at the dispatcher (packing sink)
Config.LateDeliveryPenalty  = 100  -- $ docked at return if you blew the time limit

Config.ShortRoutePayout = 400  -- $ gross for a 'short' manifest
Config.LongRoutePayout  = 750  -- $ gross for a 'long' manifest

--------------------------------------------------------------------------------
-- Timings (seconds unless noted)
--------------------------------------------------------------------------------

Config.PackingDuration   = 30   -- packing the waybill at the station
Config.UnloadingDuration = 15   -- unloading at the destination
Config.SignatureDuration = 5    -- getting the clerk to sign
Config.DeliveryTimeLimit = 900  -- assignment -> delivery; over this = late penalty

--------------------------------------------------------------------------------
-- Interaction distances (metres)
--------------------------------------------------------------------------------

Config.InteractDistance = 3.0   -- must be this close to press [E]
Config.MarkerDistance   = 15.0  -- draw markers / poll fast inside this

Config.TruckModel = 'mule'  -- box truck; 'boxville' or 'speedo' are safe alternatives

--------------------------------------------------------------------------------
-- Map blip (depot + dispatcher + active destination)
--------------------------------------------------------------------------------

Config.Blip = {
    sprite = 478,  -- box truck icon
    color  = 5,
    scale  = 0.9,
    depotLabel       = 'Waybill Depot',
    destinationLabel = 'Waybill Destination',
}

-- Ground marker drawn at every live interaction point.
Config.Marker = {
    type  = 36,
    size  = vector3(1.2, 1.2, 1.2),
    color = { r = 240, g = 180, b = 40, a = 160 },
}

--------------------------------------------------------------------------------
-- The depot: clock-in clerk, dispatcher, truck spawn + return bays
--------------------------------------------------------------------------------

Config.Depot = {
    -- Blip / centre of the yard.
    coords = vector3(708.3, -966.0, 24.9),

    -- The two static NPCs (frozen, invincible, turn to face you).
    clockerPed    = { model = 's_m_y_dockwork_01', coords = vector4(708.3, -966.0, 23.9, 90.0) },
    dispatcherPed = { model = 's_m_y_dockwork_01', coords = vector4(712.5, -966.0, 23.9, 90.0) },

    -- Where the work truck appears, and where it must be brought back.
    truckSpawn  = vector4(720.0, -975.0, 24.4, 0.0),
    truckReturn = vector4(730.0, -975.0, 24.4, 0.0),
}

--------------------------------------------------------------------------------
-- Packing stations (keep this list short — 1 or 2 entries)
--------------------------------------------------------------------------------

Config.PackingStations = {
    { coords = vector3(715.0, -962.0, 24.9), label = 'Packing Bay' },
}

--------------------------------------------------------------------------------
-- Delivery destinations (max 2 — total unique locations stays <= 3 with the depot)
-- Each carries an unload bay + the clerk who signs for the shipment.
--------------------------------------------------------------------------------

Config.DeliveryDestinations = {
    {
        label    = 'Downtown Warehouse',
        coords   = vector3(101.0, -1902.0, 24.5),
        clerkPed = { model = 's_m_m_trucker_01', heading = 320.0 },
    },
    {
        label    = 'Sandy Shores Depot',
        coords   = vector3(1704.0, 4923.0, 41.8),
        clerkPed = { model = 's_m_m_trucker_01', heading = 100.0 },
    },
}

--------------------------------------------------------------------------------
-- Manifest templates. The dispatcher assigns a random one (respecting
-- Config.Illegal). 'distance' picks the payout tier; item names must exist in
-- Config.Stock. 'packed' is added at runtime — do not set it here.
--------------------------------------------------------------------------------

Config.AvailableWaybills = {
    {
        clientName = 'Acme Logistics',
        distance   = 'short',
        isIllegal  = false,
        items = {
            { name = 'widget_box', label = 'Widget Box', qty = 5 },
            { name = 'pallet',     label = 'Pallet',     qty = 2 },
        },
    },
    {
        clientName = 'Los Santos Grocers',
        distance   = 'short',
        isIllegal  = false,
        items = {
            { name = 'produce_crate', label = 'Produce Crate', qty = 8 },
        },
    },
    {
        clientName = 'Cross-County Freight',
        distance   = 'long',
        isIllegal  = false,
        items = {
            { name = 'widget_box', label = 'Widget Box', qty = 10 },
            { name = 'pallet',     label = 'Pallet',     qty = 4 },
        },
    },
    {
        clientName = 'Unmarked Client',
        distance   = 'long',
        isIllegal  = true,
        items = {
            { name = 'sealed_crate', label = 'Sealed Crate', qty = 3 },
        },
    },
}

--------------------------------------------------------------------------------
-- Warehouse stock (server-authoritative, in memory). Packing decrements these;
-- they reset when the resource restarts. A manifest cannot be packed unless
-- every line item is in stock.
--------------------------------------------------------------------------------

Config.Stock = {
    widget_box    = 200,
    pallet        = 120,
    produce_crate = 160,
    sealed_crate  = 40,
}

--------------------------------------------------------------------------------
-- Immersion assets (verified names — do not invent). See DEVNOTES.md.
--------------------------------------------------------------------------------

Config.Anim = {
    pack      = { dict = 'anim@heists@box_carry@',            name = 'idle' },
    unload    = { dict = 'anim@heists@box_carry@',            name = 'idle' },
    signature = { dict = 'missheistdockssetup1clipboard@base', name = 'base' },
}

-- Prop held during the signature step (clipboard combo).
Config.SignatureProps = {
    { model = 'prop_notepad_01', bone = 18905, pos = vector3(0.1, 0.02, 0.05), rot = vector3(10.0, 0.0, 0.0) },
    { model = 'prop_pencil_01',  bone = 57005, pos = vector3(0.12, 0.008, 0.0), rot = vector3(-120.0, 0.0, 0.0) },
}

Config.Sound = {
    confirm  = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'SELECT' },
    step     = { set = 'HUD_MINI_GAME_SOUNDSET',        name = 'MEDAL_UP' },
    payout   = { set = 'HUD_LIQUOR_STORE_SOUNDSET',     name = 'PURCHASE' },
    error    = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'ERROR' },
    waypoint = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'WAYPOINT_SET' },
}

--------------------------------------------------------------------------------
-- ALL player-facing strings (English). Logic references keys, never literals.
-- %s / %d are filled in code. ~INPUT_PICKUP~ renders the player's [E] key.
--------------------------------------------------------------------------------

Config.Messages = {
    -- help-text prompts
    prompt_clock_in    = 'Press ~INPUT_PICKUP~ to clock in ($%d truck deposit)',
    prompt_clock_out   = 'Press ~INPUT_PICKUP~ to clock out',
    prompt_dispatcher  = 'Press ~INPUT_PICKUP~ to request a waybill',
    prompt_pack        = 'Press ~INPUT_PICKUP~ to pack the waybill',
    prompt_load        = 'Press ~INPUT_PICKUP~ to load the truck',
    prompt_unload      = 'Press ~INPUT_PICKUP~ to unload here',
    prompt_signature   = 'Press ~INPUT_PICKUP~ to get the delivery signed',
    prompt_return      = 'Press ~INPUT_PICKUP~ to return the truck',

    -- short floating labels near markers
    label_clocker      = 'Shift Office',
    label_dispatcher   = 'Dispatch',
    label_pack         = 'Packing Bay',
    label_load         = 'Truck Bay',
    label_unload       = 'Unload Bay',
    label_signature    = 'Delivery Clerk',
    label_return       = 'Truck Return',

    -- flow feedback
    clocked_in         = 'Clocked in. $%d deposit held — see the dispatcher.',
    clocked_out        = 'Clocked out. Deposit returned.',
    waybill_assigned   = 'Waybill #%d for %s: pack it at the packing bay.',
    packing_done       = 'Waybill packed. Load it into a truck at the truck bay.',
    truck_loaded       = 'Truck loaded. Deliver to %s.',
    unloaded           = 'Shipment unloaded. Get it signed by the clerk.',
    signed             = 'Signed for. Bring the truck back to the depot.',
    payout_summary     = 'Delivery paid: $%d (+$%d deposit).',
    late_notice        = 'Late delivery: -$%d penalty.',

    -- in-progress / cancel (drawn as help text during timed actions)
    busy               = 'Working... %d%%  (move away to cancel)',

    -- errors / denials
    not_allowed        = 'You are not cleared for depot work.',
    already_clocked_in = 'You are already clocked in.',
    not_clocked_in     = 'Clock in at the shift office first.',
    finish_first       = 'Finish or drop your current waybill before clocking out.',
    already_have       = 'You already have an active waybill.',
    need_deposit       = 'You need $%d for the truck deposit.',
    need_materials     = 'You need $%d for packing materials.',
    out_of_stock       = 'The warehouse is short on stock for this waybill.',
    wrong_stage        = 'You cannot do that right now.',
    truck_missing      = 'Bring the work truck to this spot first.',
    action_cancelled   = 'Action cancelled.',
    spawn_failed       = 'No truck available right now. Try again in a moment.',
}
