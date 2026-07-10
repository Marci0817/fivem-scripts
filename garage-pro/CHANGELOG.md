# Changelog — garage-pro

## [Unreleased]

### Added
- Store / retrieve across three garage types: personal, job-fleet, and impound.
- Automatic impound sweep — abandoned vehicles are towed and reclaimed for an
  impound + tow fee.
- Server-side spawning (`CreateVehicleServerSetter`), plate-ownership and
  job-access validation, per-player cooldowns, atomic fees with refund on
  spawn failure.
- `garageProImpound:alert` public event for police-dispatch integration.
- ox_lib context menu with chat + `/retrieve` fallback.
- `/givecar` ACE-gated admin test command.
- Initial scaffold on fivem-bridge (embedded).

### QA
- QA pass 1: FAIL — server-side `Bridge.Notify` call (client-only fn) in the
  impound alert handler; `sql/garage_pro.sql` listed in `fxmanifest.lua`
  `server_scripts` (not executable, load error) plus false "auto-run" claims
  in the manifest/README/DEVNOTES. Both fixed by fivem-script-builder, plus
  non-blocking cleanup (message-table migration, `lastSeen` cleanup,
  `Config.AllowJobFleetAdoption` gate against fleet laundering).
- QA pass 2 (re-run): FAIL — one residual false "auto-run" claim left in
  `sql/garage_pro.sql:3-5`, contradicting the corrected README/DEVNOTES.
  Second QA fail — per pipeline policy this stops the run rather than looping
  a third time. **Not released.** See `framework/output/garage-pro/REPORT.md`
  for the one-line fix needed before the next QA run.
