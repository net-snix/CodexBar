---
summary: "Menu bar UI, icon rendering, and menu layout details."
read_when:
  - Changing menu layout, icon rendering, or UI copy
  - Updating menu card or provider-specific UI
---

# UI & icon

## Menu bar
- LSUIElement app: no Dock icon; status item uses custom NSImage.
- Merge Icons toggle combines providers into one status item with a switcher.

## Icon rendering
- 18×18 template image.
- Top bar = 5-hour window; bottom hairline = weekly window.
- Fill represents percent remaining by default; “Show usage as used” flips to percent used.
- Dimmed when last refresh failed; status overlays render incident indicators.
- Advanced: menu bar can show provider branding icons with a percent label instead of critter bars.

## Menu card
- Session + weekly rows with resets (countdown by default; optional absolute clock display).
- Codex-only: Credits + “Buy Credits…” in-card action.
- Cost section includes an in-card refresh button (same behavior as menu “Refresh”) for usage + token-cost refresh.
- OpenAI web extras: dedicated `Usage breakdown` submenu item (not on usage-bar hover) + credits history source.
- Code review appears only when Providers → Codex → "Show Code review usage" is enabled.
- Spark appears only when Providers → Codex → "Show Codex Spark usage" is enabled.
  When OAuth provides Spark windows, the card shows `Spark Session` (5h) and `Spark Weekly` (7d) rows plus reset
  text.
  Reset text follows the global reset style setting (countdown: "Resets in …" or absolute clock/time-date).
  The Spark toggle is Pro-gated (including Spark plan identifiers such as `gpt-5.3-codex-spark`);
  non-eligible accounts show an inactive control with an explanatory message.
- Token accounts: optional account switcher bar or stacked account cards (up to 6) when multiple manual tokens exist.

## Preferences notes
- Advanced: “Disable Keychain access” turns off browser cookie import; paste Cookie headers manually in Providers.
- Providers → Claude: “Keychain prompt policy” controls Claude OAuth prompt behavior (Never / Only on user action /
  Always allow prompts).
- When “Disable Keychain access” is enabled in Advanced, the Claude keychain prompt policy remains visible but is
  inactive.

## Widgets (high level)
- Widget entries mirror the menu card; detailed pipeline in `docs/widgets.md`.

See also: `docs/widgets.md`.
