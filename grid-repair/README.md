# grid-repair

{One-line description.} Runs on **ESX**, **QBCore**, **Qbox**, or **standalone** —
the framework is auto-detected via the embedded [fivem-bridge](https://github.com/).

## Install
1. Drag `grid-repair` into your server's `resources/`.
2. Add `ensure grid-repair` to `server.cfg`.
3. (If the product ships SQL) run `sql/grid-repair.sql` once.
4. Edit `config.lua`. Restart. Done.

## Dependencies
- `oxmysql` — only for the standalone money/persistence fallback.
- `ox_lib` — optional, for nicer menus/notifications.

## Config
See `config.lua` — prices, cooldown, job gate, and locations.

## How it works
Client requests → server validates and pays out via `Bridge.*`. All money and
reward decisions are **server-authoritative**; client-sent values are re-validated.

## Support
{Discord} · {FAQ}. Free updates for buyers.
