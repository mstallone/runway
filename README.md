# Runway

AI usage across every provider and account, in the macOS menu bar.

**Website:** [runway.page](https://runway.page/)

Runway shows limits, credits, and spend for Claude, Codex, Cursor, Grok, Devin, and more in one place. Cached data appears instantly, refreshes run in the background, and the metrics you care about can sit in the menu bar.

<p align="center">
  <img src="assets/hero.png" alt="Runway hero: menu bar pins and the dashboard popover with the Total Spend ring plus Claude and Codex meters in normal, warning, and critical states" width="900">
</p>

## Installation

Download the latest universal DMG from the [releases page](https://github.com/mstallone/runway/releases/latest), open it, and drag Runway to Applications.

The app updates itself through signed, notarized [Sparkle](docs/updates.md) updates. Requires macOS 15 (Sequoia) or later.

## Performance

Runway is a fork of OpenUsage rebuilt for speed. We measured both on the same machine with the same providers and session logs. See [docs/performance.md](docs/performance.md) for the method.

| | OpenUsage | Runway |
|---|---|---|
| Launch to menu bar icon | 5.4 s | **0.29 s** |
| Popup open to first frame | 61 ms | **23 ms** |
| First open after launch | 2.59 s | **44 ms** |
| One refresh pass | 8.6 s | **2.3 s** |
| Memory (steady / peak) | 1.09 GB / 2.6 GB | **238 MB / 322 MB** |
| First-launch scan | 165 s CPU, 12.9 GB peak | **12.7 s CPU, 1.7 GB peak** |

## Supported providers

- **[Antigravity](docs/providers/antigravity.md)**: shared Gemini and Claude pool quotas, 5-hour and weekly windows
- **[Claude](docs/providers/claude.md)**: session, weekly, model-specific limits, extra usage, local daily spend
- **[Codex](docs/providers/codex.md)**: session, weekly, credits, local daily spend
- **[Copilot](docs/providers/copilot.md)**: AI credits, extra usage, organization billing, chat and completions
- **[Cursor](docs/providers/cursor.md)**: credits, total usage, Grok Bot, Cursor Models, Other Models, requests, on-demand, per-day spend
- **[Devin](docs/providers/devin.md)**: weekly and daily quota, extra usage balance
- **[Grok](docs/providers/grok.md)**: weekly shared pool, pay-as-you-go, local daily spend
- **[Kimi](docs/providers/kimi.md)**: five-hour and weekly Kimi Code quota, Extra Usage balance and monthly spend
- **[Muse](docs/providers/muse.md)**: five-hour and weekly Muse Code subscription quota
- **[OpenCode](docs/providers/opencode.md)**: Go session, weekly, and monthly caps, Zen spend, local daily spend
- **[OpenRouter](docs/providers/openrouter.md)**: credit balance, daily, weekly, and monthly spend (API key)
- **[Sakana Fugu](docs/providers/sakana.md)**: subscription quota plus local Fugu Ultra usage trend and estimated API-rate value
- **[Z.ai](docs/providers/zai.md)**: session, weekly, and web-search quotas (GLM Coding Plan, API key)

Most providers read the credentials already on your Mac (keychain, auth files, app state). OpenRouter and Z.ai have no local credential to reuse, so you supply an API key (see [OpenRouter setup](docs/providers/openrouter.md) or [Z.ai setup](docs/providers/zai.md)). Runway uses each credential only for that provider's requests. Runway collects no analytics. The [Privacy](docs/privacy.md) page covers the public pricing downloads and optional iCloud sync.

## Features

- **Menu bar pins.** Pin up to two metrics per provider to the menu bar, as text or mini bars. Metrics with no data are hidden.
- **Dashboard popover.** Meters grouped by provider, with live reset countdowns and pace indicators. Click a usage or reset value to change how it displays everywhere. Right-click a row to hide or star it, refresh its provider, or open Customize.
- **Global shortcut.** Toggle the popover from anywhere. Record any combo in Settings.
- **Customize.** Turn providers and metrics on or off, choose which rows are Always Visible or On Demand, and drag to reorder.
- **Cache first.** Cached values show instantly at launch. Refresh runs every 5 minutes.
- **[CLI](docs/cli.md).** `runway` prints limit JSON from the same five-minute cache. `runway --force` refreshes first. The app does not need to be running.
- **[Local HTTP API](docs/local-http-api.md).** Other apps can read limits from `127.0.0.1:6736/v1/limits`. The older `/v1/usage` route still works. Loopback only, never serves credentials. Browser pages can read it too. See the [privacy note](docs/local-http-api.md#cors-and-privacy).
- **[Proxy support](docs/proxy.md).** Route provider requests through SOCKS5 or HTTP(S) via `~/.runway/config.json`.
- **Native settings.** Launch at login, global shortcut, icon style, theme, 12/24-hour time. See [Settings](docs/settings.md).
- **[Automatic updates](docs/updates.md).** Signed, notarized updates via Sparkle.

## iPhone companion

Runway for iOS shows combined usage from every Mac you run: spend today, yesterday, and over the last 30 days. Data syncs privately over iCloud. Lock screen and home screen widgets can show cost or tokens. See the [iOS app](docs/ios-app.md).

<p align="center">
  <img src="assets/ios-lockscreen.png" width="270" alt="Runway lock screen widgets showing today's AI spend synced from your Macs">
  &nbsp;&nbsp;
  <img src="assets/ios-home-widgets.png" width="510" alt="Runway home screen widgets with today, yesterday, and 30-day spend plus a usage trend chart">
</p>

## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar pins](docs/menu-bar.md), [settings](docs/settings.md), [refresh and caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging and logs](docs/debugging.md).

## Requirements

- macOS 15 (Sequoia) or later
- Universal binary for Apple Silicon and Intel

Runway computes the Today, Yesterday, and Last 30 Days spend tiles from local CLI logs (Claude, Codex, Grok, Sakana Fugu) or Cursor's usage export. No Node.js or other runtime is needed. Dollars are estimated with [model pricing](docs/pricing.md).

## Development

```sh
swift build                 # debug build
swift test                  # run the test suite
./script/build_and_run.sh   # build and launch the dev app from dist/ (no install)
```

Runway is a SwiftPM package: SwiftUI content hosted in an AppKit `NSStatusItem` and a custom key-capable `NSPanel`, Swift 6 strict concurrency. The app and CLI share one module. Providers implement a small `ProviderRuntime` protocol (auth store, usage client, mapper, `ProviderSnapshot`), and both surfaces read the same normalized data. See the [architecture overview](docs/architecture.md) and [AGENTS.md](AGENTS.md) for the conventions.

Releases are automated. Pushing a stable tag on `main` tests, builds, signs, notarizes, and publishes the release. See [Releasing](docs/releasing.md).

## Contributing

Issues are welcome. Pull requests are issue-first: an external PR must link an issue a maintainer has approved with the `approved` label, or it is closed. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Report security issues privately per [SECURITY.md](SECURITY.md). The Runway name and logo are covered by the [trademark policy](TRADEMARK.md).

## License

[MIT](LICENSE)
