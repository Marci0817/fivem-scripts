# garage-pro

Store, retrieve, and reclaim vehicles across personal, job-fleet, and impound
garages — with an automatic tow sweep that turns abandoned cars into a money
sink. Runs on **ESX**, **QBCore**, **Qbox**, or **standalone** — the framework
is auto-detected via the embedded [fivem-bridge](https://github.com/).

## Install
1. Drag `garage-pro` into your server's `resources/`.
2. Add `ensure garage-pro` to `server.cfg`.
3. Import `sql/garage_pro.sql` once via oxmysql before first start (manual import
   required — it is not run automatically).
4. Edit `config.lua`. Restart. Done.

**OneSync must be enabled** — server-side vehicle creation
(`CreateVehicleServerSetter`) and the impound sweep (`GetAllVehicles`) both
require it.

## Dependencies
- `oxmysql` — required, for vehicle persistence.
- `ox_lib` — optional, for a nicer vehicle-selection menu (chat + `/retrieve`
  fallback otherwise).

## Config
See `config.lua` — fees, cooldown, free-retrieval jobs, impound timings, blips,
markers, garage locations, and all player-facing messages. `DEVNOTES.md` maps
every key to its effect.

## How it works
Client requests → server validates ownership/job/distance/cooldown and charges
via `Bridge.*`. Vehicles spawn **server-side** (`CreateVehicleServerSetter`) and
the client only ever receives a network id. All money and spawn decisions are
**server-authoritative**; client-sent values are re-validated.

## Integrations
`garageProImpound:alert` fires whenever a vehicle is towed — hook it for
police-dispatch, phone or paperwork resources (payload in `DEVNOTES.md`).

## Support
{Discord} · {FAQ}. Free updates for buyers.
