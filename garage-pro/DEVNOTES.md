# garage-pro — developer notes

Framework-agnostic vehicle garage system (ESX / QBCore / Qbox / standalone via
the embedded bridge). Everything a server owner touches lives in `config.lua`;
the logic never holds a coordinate, price, job name or player-facing string.

## What this script does

Players **store** the vehicle they are driving at a garage and **retrieve** it
later for a fee. Three garage types share one code path: **personal** (your own
cars), **job** (a shared fleet for a matching job), and **impound** (reclaim
towed vehicles). A background sweep automatically **impounds** vehicles left
unattended in the world, charging an impound + tow fee to get them back — a
money sink and a hook for police-dispatch resources.

## Where to tweak what

| I want to change… | Edit this | Notes |
|---|---|---|
| Retrieve fee | `Config.RetrieveFee` | $, charged on pull-out (exempt jobs below) |
| Impound + tow cost | `Config.ImpoundFee`, `Config.TowFee` | $, charged together on reclaim, never exempt |
| Which account pays | `Config.FeeAccount` | `'cash'` or `'bank'` (bridge maps per framework) |
| Free-retrieval jobs | `Config.FreeForJobs` | `{ jobname = true }`; matched on `Bridge.GetJob().name` |
| Garage locations | `Config.Garages` | see "Adding a location" below |
| Blip look per type | `Config.Blip[type]` | `sprite`, `color`, `scale`, `label` |
| Marker look per type | `Config.Marker[type]` | `type`, `size`, `color` |
| Interaction range | `Config.MarkerDistance`, `Config.InteractDistance` | m; marker draw / [E] range |
| Anti-spam delay | `Config.Cooldown` | ms, per player, server-enforced |
| How fast impound reacts | `Config.ImpoundCheckInterval` | ms between sweeps (~30s granularity) |
| Abandon grace period | `Config.AbandonedVehicleTimer` | ms a car may sit unattended before towing |
| Impound aggressiveness | `Config.ImpoundChance` | %, roll per eligible vehicle per sweep (100 = always) |
| Police alerts on/off | `Config.ImpoundAlertEnabled` | notifies on-duty police jobs |
| Which jobs are police | `Config.PoliceJobNames` | array of job names that receive alerts |
| Any on-screen text | `Config.Messages` | English keys; see "Message texts" |

## Adding a location

Append to `Config.Garages`. `spawn` is a `vector4` (x, y, z, heading). `type` is
one of `'personal'`, `'job'`, `'impound'`; `job` is REQUIRED only for `'job'`.

```lua
-- Personal garage
{
    type   = 'personal',
    label  = 'Vinewood Garage',
    coords = vector3(-337.1, -132.4, 39.0),
    spawn  = vector4(-325.6, -128.9, 38.7, 70.0),
},

-- Job garage (shared fleet — every member of `job` sees the same vehicles)
{
    type   = 'job',
    label  = 'EMS Bay',
    job    = 'ambulance',
    coords = vector3(294.9, -574.4, 43.2),
    spawn  = vector4(299.0, -581.9, 43.2, 70.0),
},

-- Impound lot (players reclaim towed vehicles here)
{
    type   = 'impound',
    label  = 'Sandy Impound',
    coords = vector3(1638.0, 3803.0, 34.0),
    spawn  = vector4(1631.0, 3810.0, 34.0, 20.0),
},
```

The blip and marker are chosen automatically from `Config.Blip[type]` /
`Config.Marker[type]` — no per-location wiring needed.

## Message texts

All player-facing strings live in `Config.Messages` (English). Logic references
keys only — change the text and nothing else moves. Keys with `%d`/`%s` are
formatted in code; the placeholder order is documented inline in `config.lua`
(e.g. `retrieve_insufficient` takes the fee, `impound_alert_text` takes the plate).

## Events other resources can listen to

`garageProImpound:alert` — fired server-side every time a vehicle is towed by
the automatic sweep. Listen to it to drive a custom police/dispatch UI, a phone
notification, a paperwork job, etc. The built-in handler (guarded by
`Config.ImpoundAlertEnabled`) simply notifies on-duty police.

```lua
AddEventHandler('garageProImpound:alert', function(data)
    -- data.plate    : string  — the towed vehicle's plate
    -- data.owner_id : string  — owner identifier (Bridge.GetIdentifier value)
    -- data.coords   : vector3 — where the vehicle was towed from
    -- data.fee      : number  — total it will cost the owner to reclaim
end)
```

To replace the default behaviour, set `Config.ImpoundAlertEnabled = false` and
handle the event yourself.

## Admin test command

`/givecar [model]` (default `sultan`) seeds a stored vehicle in the caller's
Legion Square garage so QA can exercise store/retrieve/impound. ACE-gated:
add `add_ace group.admin command.givecar allow` to `server.cfg`.

## Known limits

- **Impound granularity** — the sweep runs every `Config.ImpoundCheckInterval`
  (~30s), so a vehicle is towed up to one interval after its grace period ends.
  Occupancy is measured by the driver seat only.
- **Fleet impound** — job/fleet vehicles are keyed to the job, but impound
  reclaim is owned by the individual identifier. A towed fleet vehicle is a
  corner case not covered in this MVP.
- **Storage tax / insurance are deferred to v1.1** — this MVP ships exactly two
  sinks (retrieve fee, impound + tow) by design.
- **oxmysql required** — import `sql/garage_pro.sql` once via oxmysql before
  first start (manual import required — it is not run automatically). Vehicle
  rows are created by `/givecar` or by whatever dealership/purchase resource
  writes to `owned_vehicles`.
