# waybill-delivery

Pack real items into a waybill, haul it across the city, and get a signed
delivery confirmation. Runs on **ESX**, **QBCore**, **Qbox**, or **standalone** —
the framework is auto-detected via the embedded [fivem-bridge](https://github.com/).

## Install
1. Drag `waybill-delivery` into your server's `resources/`.
2. Add `ensure waybill-delivery` to `server.cfg`.
3. This product ships **no SQL of its own** — waybill state is transient per
   delivery run. **Standalone servers** (no ESX/QBCore/Qbox) must still import
   the bridge's money table once: run `sql/bridge.sql` from the bridge repo root
   via oxmysql before first use. Without it the standalone money fallback fails,
   `Bridge.RemoveMoney` returns `false`, and clock-in is denied.
4. Edit `config.lua`. Restart. Done.

## Dependencies
- `oxmysql` — only for the bridge's standalone money fallback (already present
  on any ESX/QB/Qbox server). Standalone servers also run `sql/bridge.sql` from
  the bridge repo once.
- `ox_lib` — optional, for nicer menus/notifications.

## Config
See `config.lua` — prices, cooldown, job gate, and locations.

## How it works
Client requests → server validates and pays out via `Bridge.*`. All money and
reward decisions are **server-authoritative**; client-sent values are re-validated.

## Support
{Discord} · {FAQ}. Free updates for buyers.
