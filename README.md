# CodexBar (Codex-only fork)

CodexBar is a macOS menu bar app for Codex usage visibility.

This fork (`net-snix/CodexBar`) is intentionally Codex-only in active runtime behavior, with a performance and battery focus.

<img src="codexbar.png" alt="CodexBar menu screenshot" width="520" />

## Project status

- Runtime scope: Codex only.
- App target: macOS menu bar app first.
- Secondary target: Linux/macOS CLI output for scripts/CI.
- Current branch keeps some legacy provider code/docs in-tree as reference, but provider iteration is restricted to Codex.

## What this fork changes

Compared to upstream, this fork currently applies these practical deltas:

- `UsageProvider.allCases` resolves to `codex` only, so refresh/provider loops run Codex only.
- refresh, status polling, and token refresh loops execute only for enabled providers (now effectively Codex).
- Codex credits fetch is integrated into provider refresh (no extra standalone credits refresh pass).
- widget timeline reload is snapshot-diffed and minimum-interval throttled.
- release automation includes GitHub Actions for:
  - signed/notarized macOS app releases
  - Linux CLI release artifacts

## Features (active)

- Codex session and weekly usage with reset times.
- Codex credits in app + CLI output.
- Codex source fallback strategy:
  - OpenAI web dashboard (cookie-based, optional)
  - Codex CLI RPC (`codex app-server`)
  - Codex CLI PTY fallback (`/status`)
- OpenAI status indicator integration.
- local token/cost usage scan from Codex session logs.
- Widget snapshot persistence for Codex usage.
- `codexbar` CLI for terminal and CI workflows.

## Requirements

- macOS 14+ for the menu bar app.
- Xcode + Swift toolchain for local builds.
- `codex` CLI installed and authenticated for CLI/RPC data paths.

## Install

### Download release

- [GitHub Releases](https://github.com/net-snix/CodexBar/releases)

### Build locally

```bash
swift build -c release
./Scripts/package_app.sh
open CodexBar.app
```

### Dev loop (build, test, package, relaunch)

```bash
./Scripts/compile_and_run.sh
```

## CLI usage

`CodexBar.app` ships `CodexBarCLI` at:

`CodexBar.app/Contents/Helpers/CodexBarCLI`

Optional symlink:

```bash
ln -sf "$PWD/CodexBar.app/Contents/Helpers/CodexBarCLI" /usr/local/bin/codexbar
```

Examples:

```bash
codexbar usage --provider codex
codexbar usage --provider codex --format json --pretty
codexbar usage --provider codex --source cli
codexbar usage --provider codex --status
codexbar cost --provider codex --format json --pretty
```

## Performance and battery notes

This fork prioritizes lower background churn:

- provider fan-out reduced to Codex runtime path
- duplicate credits refresh path removed
- widget timeline reloads avoided when snapshot did not materially change
- widget timeline reload frequency minimum interval enforced

For even lower background activity, use Settings to:

- increase refresh interval
- disable status checks
- run manual refresh only

## GitHub Actions release flows

### `Release macOS App`

File: `.github/workflows/release-macos.yml`

Triggers:

- `release.published` (uploads assets directly to release)
- `workflow_dispatch` (uploads artifacts to the workflow run)

Required repository secrets:

- `APPLE_DEVELOPER_ID_CERT_P12_BASE64`
- `APPLE_DEVELOPER_ID_CERT_PASSWORD`
- `APP_IDENTITY` (recommended)
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`

### `Release Linux CLI`

File: `.github/workflows/release-cli.yml`

Triggers:

- `release.published`
- `workflow_dispatch`

Build matrix:

- `linux-x64` (`ubuntu-24.04`)
- `linux-arm64` (`ubuntu-24.04-arm`)

## Data + privacy

CodexBar reads only targeted Codex-related paths as needed:

- `~/.codex/auth.json` (OAuth/token flow)
- `~/.codex/sessions/**` and `~/.codex/archived_sessions/**` (cost usage)
- optional browser cookies when OpenAI web dashboard mode is enabled

No broad disk crawling. Cookie usage is opt-in.

## macOS permissions

- Full Disk Access may be needed for Safari cookie import.
- Keychain prompts can occur for browser safe-storage decryption.
- Accessibility / Screen Recording / Automation permissions are not required.

## Docs

- `docs/codex.md` - Codex data sources and fetch details
- `docs/providers.md` - provider strategy map (includes codex-only runtime note)
- `docs/refresh-loop.md` - refresh timing + lifecycle behavior
- `docs/cli.md` - CLI behavior and flags
- `docs/RELEASING.md` - release checklist and signing/notarization flow

## License

MIT
