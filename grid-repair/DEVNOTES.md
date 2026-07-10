# grid-repair — developer notes

## What this script does

grid-repair is a freelance emergency-electrician gig. The server periodically
trips a random power box (from `Config.Locations`) into an outage and records
when it failed. Any player — no framework job required — can drive to the
blipped box, press [E], pay for a fuse kit, and clear a short fuse-sequence
minigame to restore power. **Payout scales with how long the outage has been
active**, so responding to a far-away / neglected box pays more than camping the
nearest one. State is fully server-authoritative and ephemeral (in-memory, no
SQL).

## Where to tweak what

| I want to change… | Edit this | Notes |
|---|---|---|
| Base pay + age curve | `Config.BasePayout`, `Config.PayoutPerSecond`, `Config.MaxAgeBonus` | payout = Base + min(ageSeconds × PerSecond, MaxAgeBonus) |
| Fuse-kit cost (SINK 1) | `Config.FuseKitCost` | charged up front every attempt |
| Refund the kit on failure | `Config.RefundOnFail` | `false` = kit is a real sink (default) |
| Repeated-failure penalty (SINK 2) | `Config.RepeatFail` | `threshold`, `surcharge`, `resetOnPass` |
| Retry lockout after a fail | `Config.RetryCooldown` | ms, server-enforced per player |
| Money account | `Config.Account` | `'cash'` or `'bank'` |
| How often outages appear | `Config.Outage.intervalMin/Max` | ms, randomized each cycle |
| How many outages at once | `Config.Outage.maxActive` | keep ≤ `#Config.Locations` |
| Outages present on restart | `Config.Outage.startFailed` | seeded immediately |
| Minigame difficulty | `Config.Minigame` | `fuseCount`, `sequenceLength`, `timeLimit` (ms) |
| Interaction range / key | `Config.Interact` | `key`, `markerDistance`, `interactDistance` (m) |
| Marker look | `Config.Marker` | type/size/color |
| Failed-box particle | `Config.Ptfx` | asset/effect/scale/zOffset |
| Repair anim + tool prop | `Config.Anim`, `Config.Prop` | verified GTA assets — don't invent names |
| Outcome sounds | `Config.Sounds` | success/fail/payout frontend sounds |
| Blip look | `Config.Blip` | sprite/color/scale/label |
| Locations | `Config.Locations` | see "Adding a location" below |
| Texts shown to players | `Config.Messages` | English keys, logic never holds strings |

### The two economy sinks (required reading before you rebalance)

- **SINK 1 — Fuse kit:** `Config.FuseKitCost` is removed via `Bridge.RemoveMoney`
  *before* the minigame starts. Modeled as a flat cash fee because the bridge has
  no inventory API yet (see "Known limits"). With `Config.RefundOnFail = false`
  the kit is consumed even on a failed repair, so every attempt has a real cost.
- **SINK 2 — Repeated-failure penalty:** each failed attempt starts a
  `Config.RetryCooldown` lockout and increments a consecutive-fail counter. Once
  that counter reaches `Config.RepeatFail.threshold`, each further failure also
  deducts `Config.RepeatFail.surcharge` ("damaged equipment"). A successful
  repair resets the counter when `Config.RepeatFail.resetOnPass` is true.

## Adding a location

Max 3 locations by design (scope discipline). Append to `Config.Locations`:

```lua
Config.Locations = {
    { coords = vector3(2743.6, 1555.4, 24.5), label = 'Palmer-Taylor Substation' },
    -- new box:
    { coords = vector3(120.0, -1050.0, 29.0), label = 'Mission Row Feeder Box' },
}
```

Each entry: `coords` (vector3, ground level — the marker is drawn 1.0m below and
the particle `Config.Ptfx.zOffset` above), and `label` (used in the blip and the
`new_outage` notification). The blip/marker/particle look is shared from
`Config.Blip` / `Config.Marker` / `Config.Ptfx` — there is no per-location
override. If you add a 4th+ location it will still work, but raise
`Config.Outage.maxActive` if you want more simultaneous outages.

## Message texts

All player-facing strings live in `Config.Messages` (English). Logic references
keys only — change the text here, nothing else moves. Format specifiers:
`success` / `no_kit` / `surcharge` take a `$` amount, `on_cooldown` takes seconds,
`new_outage` takes the location label.

## Events other resources can listen to

All are standard net events (server → client), safe to `RegisterNetEvent` from
another resource:

| Event | Direction | Payload | Fires when |
|---|---|---|---|
| `grid-repair:outageStarted` | server → all clients | `index` (number, index into `Config.Locations`) | a box trips into an outage |
| `grid-repair:outageCleared` | server → all clients | `index` (number) | a box is repaired / reset |
| `grid-repair:repairResult` | server → the repairer | `ok` (boolean) | that player's repair resolves |

You can force an outage from the server console with `gridfail` (testing/events).

## Known limits

- **No inventory integration.** The fuse kit is a flat cash fee, not a consumed
  item, because `Bridge.*` has no inventory API yet. If/when an inventory bridge
  function is added, SINK 1 should switch to consuming a real "fuse kit" item.
  (Flagged for `/bridge-add`.)
- **Ephemeral state.** Outages live in a server-side table only. A resource
  restart wipes all active outages and per-player cooldown/fail streaks, then
  re-seeds `Config.Outage.startFailed` fresh. This is intentional — it is world
  state, not player data, so there is no SQL.
- **Minigame validation is sequence + server clock.** The server generates the
  fuse sequence and validates the returned order and its own elapsed time; it
  does not stream individual key/click events. A modified client could in theory
  replay the known sequence, but it still cannot fake payout, distance, cooldown,
  the up-front kit charge, or the lock — those are all server-side.
- **Placeholder NUI widget.** `html/` is a functional placeholder (shows the
  target sequence, type-to-enter, Esc to cancel). The polished fuse-button widget
  is built in the nui-developer stage against the contract in
  `client/main.lua` ("NUI CONTRACT").
- **Location coords** are reasonable defaults near real GTA V substations; verify
  each sits flush on the ground for your map/props and nudge `z` if needed.
