---
summary: "Refresh cadence, background updates, and error handling."
read_when:
  - Changing refresh cadence, background tasks, or refresh triggers
  - Investigating refresh timing or stale data behavior
---

# Refresh loop

## Cadence
- `RefreshFrequency`: Manual, 1m, 2m, 5m (default), 15m, 30m.
- Stored in `UserDefaults` via `SettingsStore`.

## Behavior
- Background refresh runs off-main and updates `UsageStore` (usage + credits + optional web scrape).
- Polls align to cadence boundaries (`5m` => `:00/:05/:10/...`) instead of drifting from app launch time.
- Token-cost usage refresh interval follows the selected refresh cadence.
- Manual refresh available via the menu “Refresh” action and the in-card Cost refresh button.
- Stale/error states dim the icon and surface status in-menu.

## Optional future
- Auto-seed a log if none exists via `codex exec --skip-git-repo-check --json "ping"` (currently not executed).

See also: `docs/status.md`, `docs/ui.md`.
