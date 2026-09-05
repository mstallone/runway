# AGENTS.md

Runway is a SwiftPM SwiftUI menu-bar app for macOS. It shows usage widgets for AI providers (Claude, Codex, Cursor, Grok, Devin, and more). This file holds the engineering conventions. Read it before you contribute.

AGENTS.md is the only place for agent instructions. CLAUDE.md contains `@AGENTS.md` and nothing else.

Active development happens on `main`. The old Tauri edition is frozen on the `tauri-legacy` branch.

## Architecture

- SwiftPM executable target. SwiftUI content is hosted in an AppKit `NSStatusItem` and a custom key-capable `NSPanel`.
- Swift 6 with strict concurrency.
- Each provider implements `ProviderRuntime`: an auth store reads credentials already on the machine, a usage client calls the provider API, and a mapper turns the response into `MetricLine` values. The UI renders those values.
- `docs/` holds the behavior docs and the developer docs (architecture, adding a provider).

## Providers

Provider modules live under `Sources/Runway/Providers/<Name>/`.

- **Structure.** One folder per provider: auth store, usage client, mapper. The module conforms to `ProviderRuntime` with `refresh()` and `hasLocalCredentials()`. `hasLocalCredentials()` is a local-only check. `FirstRunSeeder` calls it on a fresh install, and `NewProviderSeeder` calls it once when a new provider ships. It must check the same credential sources and usability filters that `refresh()` uses, through the same auth-store loaders. Do not add a second credential-reading path. See `docs/adding-a-provider.md` and `docs/provider-enablement.md`.
- **Pricing.** All spend estimates (Claude, Codex, Cursor, Grok) go through `Sources/Runway/Pricing/` (see `docs/pricing.md`). Cursor-native model rates and alias rules live in `Sources/Runway/Resources/pricing_supplement.json`. Sync new or changed models from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md): update `updated_at`, the pricing entries, and the `alias_rules`. A merge to `main` publishes the file to `update-feed`, so installed apps pick it up without a release. Regenerate the bundled LiteLLM and models.dev snapshots with `script/update_pricing_snapshots.sh` before a release.
- **Default order.** Claude, Codex, Cursor, then every other provider alphabetically by display name. The order is the array order in `AppContainer`, which seeds the default order in `LayoutStore`.
- **Metric defaults.** When you add or change a metric, confirm these four defaults with the owner. Never pick them yourself:
  1. enabled on or off (`DefaultLayout.metricIDs`),
  2. Always Visible or On Demand (`DefaultLayout.expandedMetricIDs`). Keep at least one metric Always Visible per provider. If every metric is On Demand, the dashboard promotes all of them and the caret disappears,
  3. pinned to the menu bar (`DefaultLayout.pinnedMetricIDs`),
  4. order within the provider (the `widgetDescriptors` declaration order).

## Releases

Releases ship from `.github/workflows/release.yml` with a Sparkle appcast on `update-feed`. Cut them with the release-swift skill. `docs/releasing.md` covers the secrets and one-time setup.

- Versions are `0.7.x` and up. Never reuse a `0.6.x` number. Those belong to the Tauri edition (final release `v0.6.28`).
- Never bump the version on your own. Propose a number and wait for the owner's explicit approval before tagging or releasing.
- Tags are plain `vMAJOR.MINOR.PATCH` and become the GitHub "Latest" release. No prerelease suffixes and no Sparkle beta channel.
- Do not carry over the upstream fork's Tauri `latest.json`, release assets, appcast entries, or signing identity.
- Never leave a release in Draft or with empty notes. The release-swift skill writes the changelog and verifies the published release.

## Testing changes

There is no hot reload. Kill the running app, rebuild, and relaunch before you test a change.

## Pull requests

Every PR description uses this structure:

- **TL;DR**: one or two sentences.
- **What was happening**: the prior behavior, bug, or gap.
- **What this changes**: what the PR does.
- **Heads-up** (optional): risks, follow-ups, trade-offs.
- **Tests** (optional): how you verified it.

## Documentation

- A logic change must update every page in `docs/` that describes the affected behavior.
- Keep docs simple and easy to skim. Describe behavior, not visual design.

## Code

- Add a regression test when you fix a bug.
- Keep files under about 500 lines.
- No new dependencies without a reason.
- Fail loudly into the local log file and show a friendly error to the user. No silent fallbacks. Validate only at system boundaries (user input, external APIs). Trust internal code.

## UI

- Use title case for hardcoded titles.
- Match the existing design language.
- Add tooltips (`hoverTooltip`) only when asked.
