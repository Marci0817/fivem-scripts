-- grid-repair configuration.
-- Everything tunable lives here. No coords/prices/timings hard-coded in logic.
-- Units are commented on every key. See docs/agentic/STYLE_GUIDE.md.

Config = {}

Config.Debug = false -- true = print outage lifecycle to the server/client console

--------------------------------------------------------------------------------
-- Money
--------------------------------------------------------------------------------

Config.Account = 'cash' -- 'cash' | 'bank' (bridge normalizes per framework)

-- Payout = BasePayout + min(outageAgeSeconds * PayoutPerSecond, MaxAgeBonus).
-- Older outages pay more, so players are rewarded for driving to a neglected /
-- far-away box instead of camping the nearest one.
Config.BasePayout     = 250   -- $, paid on every successful repair
Config.PayoutPerSecond = 2     -- $ added per second the outage has been active
Config.MaxAgeBonus    = 1500  -- $, cap on the age bonus (reached at 750s here)

--------------------------------------------------------------------------------
-- Economy sinks (see DEVNOTES.md "Where to tweak what")
--------------------------------------------------------------------------------

-- SINK 1 — Fuse kit (per-use consumable, modeled as a flat cash fee because the
-- bridge has no inventory API yet). Charged UP FRONT before the minigame starts.
Config.FuseKitCost  = 100   -- $, deducted via Bridge.RemoveMoney before every attempt
Config.RefundOnFail = false -- false = kit is consumed even on a failed repair (a real sink)

-- SINK 2 — Repeated-failure penalty. After too many consecutive failures the
-- responder is charged a "damaged-equipment" surcharge and put on a retry cooldown.
Config.RepeatFail = {
    threshold   = 2,     -- consecutive failures before the surcharge applies
    surcharge   = 150,   -- $, extra fee deducted on each failure at/over the threshold
    resetOnPass = true,  -- true = a successful repair clears the consecutive-fail counter
}

-- Applied after ANY failed attempt: the responder cannot start a new repair until
-- this elapses (server-enforced, per player). Doubles as anti-spam.
Config.RetryCooldown = 15000 -- ms

--------------------------------------------------------------------------------
-- Outage scheduler (server-side, in-memory ephemeral state — no SQL)
--------------------------------------------------------------------------------

-- The server wakes on a randomized interval and, if a non-failed box exists,
-- trips a random one. Keeps outages appearing at unpredictable times.
Config.Outage = {
    intervalMin = 90000,  -- ms, shortest gap between new outages
    intervalMax = 240000, -- ms, longest gap between new outages
    maxActive   = 2,      -- most outages live at once (<= #Config.Locations)
    startFailed = 1,      -- how many boxes are already failed when the resource starts
}

--------------------------------------------------------------------------------
-- Fuse-sequence minigame (server generates the sequence; client only renders it)
--------------------------------------------------------------------------------

Config.Minigame = {
    fuseCount      = 5,     -- number of fuses/switches shown in the widget
    sequenceLength = 4,     -- how many presses make up the correct sequence
    timeLimit      = 12000, -- ms, hard limit; server also enforces this as a max
}

--------------------------------------------------------------------------------
-- Interaction (the garage idiom — variable-wait proximity loop)
--------------------------------------------------------------------------------

Config.Interact = {
    key             = 38,   -- INPUT_PICKUP ([E] by default)
    markerDistance  = 20.0, -- m, start drawing the marker within this range
    interactDistance = 2.0, -- m, show help text + accept [E] within this range
}

-- Ground marker drawn on a failed box while you are near it.
Config.Marker = {
    type  = 1,
    size  = vector3(1.0, 1.0, 0.6),
    color = { r = 255, g = 120, b = 0, a = 160 }, -- amber = something's wrong here
}

-- Electric-crackle particle looped on a failed box so an outage reads at a glance.
Config.Ptfx = {
    asset  = 'core',
    effect = 'ent_amb_elec_crackle',
    scale  = 1.0,
    zOffset = 0.5, -- m, raise the FX off the ground toward the panel
}

--------------------------------------------------------------------------------
-- Immersion (assets verified via search_game_assets — do not invent names)
--------------------------------------------------------------------------------

Config.Anim = {
    dict = 'mini@repair',   -- two-hand fiddly repair loop
    name = 'fixing_a_ped',
}

Config.Prop = {
    model   = 'hei_prop_heist_drill', -- handheld tool during the repair anim
    bone    = 28422,                  -- PH_R_Hand — aligns tool-like props to the right hand
    offset  = vector3(0.0, 0.0, 0.0),
    rot     = vector3(0.0, 0.0, 0.0),
}

Config.Sounds = {
    success = { name = 'MEDAL_UP',   set = 'HUD_MINI_GAME_SOUNDSET' },       -- repair cleared
    fail    = { name = 'LOOSE_MATCH', set = 'HUD_MINI_GAME_SOUNDSET' },      -- repair failed
    payout  = { name = 'PURCHASE',   set = 'HUD_LIQUOR_STORE_SOUNDSET' },    -- money ka-ching
}

--------------------------------------------------------------------------------
-- Blip (shown only while a box is failed; removed the moment it's repaired)
--------------------------------------------------------------------------------

Config.Blip = {
    sprite = 354,  -- lightning-ish spanner sprite; tune to taste
    color  = 47,   -- yellow
    scale  = 0.9,
    label  = 'Power Outage',
}

--------------------------------------------------------------------------------
-- Locations (max 3 — scope discipline). Each is a power box that can fail.
-- See DEVNOTES.md "Adding a location" for the exact shape.
--------------------------------------------------------------------------------

Config.Locations = {
    { coords = vector3(2743.6, 1555.4, 24.5),   label = 'Palmer-Taylor Substation' },
    { coords = vector3(-544.5, -1740.0, 19.0),  label = 'La Puerta Feeder Box' },
    { coords = vector3(1717.5, 4787.0, 42.0),   label = 'Sandy Shores Transformer' },
}

--------------------------------------------------------------------------------
-- Messages — ALL player-facing strings (English). Logic references keys only.
--------------------------------------------------------------------------------

Config.Messages = {
    prompt_repair    = 'Press ~INPUT_PICKUP~ to repair the power box',
    started          = 'Diagnosing the fault — match the fuse sequence',
    success          = 'Power restored! Payout: $%d',
    failed           = 'The fuses blew — repair failed',
    timeout          = 'You ran out of time — repair failed',
    cancelled        = 'You stopped the repair',
    no_kit           = 'You need $%d for a fuse kit',
    surcharge        = 'Equipment damaged — extra $%d for replacement tools',
    on_cooldown      = 'Your tools are still cooling down — wait %d s',
    already_working  = 'Someone is already working on that box',
    not_failed       = 'That box is working fine',
    too_far          = 'Get closer to the power box',
    new_outage       = 'Power outage reported: %s',
}
