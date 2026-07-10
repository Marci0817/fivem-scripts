# waybill-delivery — developer notes

<!-- The builder fills every TODO below during the build stage. QA verifies
     that the config keys named here actually exist in config.lua. -->

## What this script does

A single-loop delivery job: clock in at a depot (posts a truck deposit),
take a waybill from the dispatcher (a manifest of physical items + a
destination + a payout), pack it at the packing bay, load it into a truck,
drive it to the destination, unload, get the delivery clerk to sign for it
(proof of delivery), then drive the truck back and return it for your payout
and deposit refund. Legal and black-market (`Config.Illegal`) variants share
the same loop; illegal runs pay more and fire a hookable police-alert event.

## Where to tweak what

| I want to change… | Edit this | Notes |
|---|---|---|
| Payouts per route | `Config.ShortRoutePayout`, `Config.LongRoutePayout` | picked by a manifest's `distance` field |
| Vehicle deposit | `Config.VehicleDeposit` | held on clock-in, refunded on truck return, forfeited on disconnect |
| Packing materials cost | `Config.PackingMaterialsCost` | charged up-front at the dispatcher, not deducted again at payout |
| Late penalty | `Config.LateDeliveryPenalty` | applied at truck return if `Config.DeliveryTimeLimit` was exceeded |
| Illegal payout multiplier | `Config.IllegalPayoutMultiplier` | applied to net payout on illegal waybills |
| Allow/deny illegal runs | `Config.Illegal` | when `false`, only legal manifests are ever assigned |
| Job gating | `Config.AllowedJobs` | `nil` = anyone; else a set like `{ trucker = true }` checked against `Bridge.GetJob(src).name` |
| Timings | `Config.PackingDuration`, `Config.UnloadingDuration`, `Config.SignatureDuration`, `Config.DeliveryTimeLimit` | seconds |
| Interaction/marker range | `Config.InteractDistance`, `Config.MarkerDistance` | metres |
| Work vehicle | `Config.TruckModel` | must be a truck/van model the server has streamed |
| Depot layout | `Config.Depot` | clock-in/dispatcher NPC coords, truck spawn + return bays |
| Packing stations | `Config.PackingStations` | see "Adding a location" below |
| Delivery destinations | `Config.DeliveryDestinations` | see "Adding a location" below |
| Manifests | `Config.AvailableWaybills` | item names must exist in `Config.Stock` |
| Warehouse stock | `Config.Stock` | in-memory; resets on resource restart |
| Texts shown to players | `Config.Messages` | English keys, logic never holds strings |

## Adding a location

**Packing station** — append to `Config.PackingStations`:
```lua
{ coords = vector3(x, y, z), label = 'Packing Bay 2' }
```

**Delivery destination** — append to `Config.DeliveryDestinations` (keep this
list short — 1-2 entries, per the factory's 3-location scope cap alongside the
depot):
```lua
{
    label    = 'Your Location Name',
    coords   = vector3(x, y, z),
    clerkPed = { model = 's_m_m_trucker_01', heading = 0.0 },  -- signs for the delivery
}
```
The dispatcher picks a destination at random per waybill; there's no
per-manifest destination pinning.

## Message texts

All player-facing strings live in `Config.Messages` (English). Logic
references keys only — change the text here, nothing else moves.

## Events other resources can listen to

- `waybill:deliveryConfirmed` — fired when the clerk signs (proof of
  delivery). Payload: `{ playerId, waybillId, destination, basePayout, isIllegal }`.
- `waybill:policeAlert` — fired only when `isIllegal` and the clerk signs.
  Payload: `{ coords, waybillId }`. Hook this from a police dispatch resource.

## Known limits

- **One waybill per player at a time.** No queueing; you must finish (deliver
  + return the truck) or disconnect before starting another.
- **No cancel/abandon path while connected.** If you can't complete a waybill
  (e.g. stock runs out mid-run), the only way out is disconnecting — which
  forfeits the deposit and clears the waybill. This is intentional (the
  deposit is the abandonment cost), not a bug.
- **No persistence.** All waybill/duty/stock state is in memory; a resource
  restart wipes active runs and resets `Config.Stock` to its config defaults.
  If you want deliveries logged, hook `waybill:deliveryConfirmed` from another
  resource and write to your own database.
- **No SQL ships with this resource.**
- **Packing materials are charged once, up front**, at waybill assignment —
  not subtracted again from the final payout. `wb.packingCost` is recorded on
  the waybill for reference only.
- **Framework support:** ESX, QBCore, Qbox, standalone — all through the
  embedded `Bridge.*` calls (`Notify`, `GetIdentifier`, `GetJob`, `GetMoney`,
  `AddMoney`, `RemoveMoney`). No raw framework object is ever touched.
