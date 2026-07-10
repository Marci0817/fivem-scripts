# Changelog — waybill-delivery

## [Unreleased]

### Added
- Initial scaffold on fivem-bridge (embedded).
- Core loop: clock-in/deposit, dispatcher-assigned waybills, packing, truck
  load/drive/unload, clerk signature (proof of delivery), truck return +
  payout, illegal/legal variants, one compact overlay widget (waybill
  manifest).

### Fixed
- README wrongly implied standalone needed no SQL at all; documented that
  standalone servers must import the bridge's `sql/bridge.sql` once.
- TOCTOU double-reward window on standalone (money calls yield via oxmysql
  await): fixed in `returnTruck`, `clockIn`, `requestWaybill` by clearing/
  reserving state before the yielding `Bridge.*` money call.

### Known issue (QA-blocking, unresolved)
- The same TOCTOU double-refund pattern still exists in `clockOut`
  (`server/main.lua`): the vehicle deposit refund is paid via
  `Bridge.AddMoney` before `duty[id]`/`idBySrc[src]` are cleared, so a rapid
  double-fire on a **standalone** server can refund the deposit twice. Not
  exploitable on ESX/QBCore/Qbox (their `AddMoney` is synchronous). Fix is the
  same capture-then-clear reorder already applied to the other three handlers.
  This is the second QA fail on this run, so per pipeline policy the run
  stopped here rather than looping a third remediation pass — needs a human
  or a follow-up run to land the fix and re-run QA before release.
