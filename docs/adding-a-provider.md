# Adding a Provider

How to add a new AI provider to Runway. Read the [architecture overview](architecture.md) first.

## What a provider is

A provider is a small Swift module under `Sources/Runway/Providers/<Name>/` that conforms to `ProviderRuntime`. It has three parts:

- an **auth store** that reads credentials already on the user's machine (config files, keychain),
- a **usage client** that calls the provider's API,
- a **mapper** that turns the response into metric lines.

Runway never asks the user to paste a token. If the provider's own CLI or app is logged in, Runway reads that login.

Besides `refresh()`, every provider implements `hasLocalCredentials()`: a cheap, local-only check (files, keychain, never the network) for whether credentials exist. A fresh install calls it once to turn on the providers the user has (`FirstRunSeeder`). Existing installs call it once on the first launch after your provider ships (`NewProviderSeeder`). See [Which Providers Are On](provider-enablement.md). Check the same credential sources `refresh()` reads, and run blocking loads via `loadOffMainActor`.

## The metric contract

`refresh()` returns a `ProviderSnapshot` whose `lines` are `MetricLine` values. Pick the case by the shape of the number:

- **`.progress`**: a bounded meter with `used`, `limit`, and a `format`:
  - `.percent` for quota-style limits (session, weekly),
  - `.dollars` for a capped dollar amount,
  - `.count(suffix:)` for a capped count (requests per cycle).
  - Add `resetsAt` when the window resets at a known time, and `periodDurationMs` for the cycle length.
- **`.values`**: an unbounded row with one or more raw numbers. Each is a `MetricValue`: a number, its kind, and an optional unit label like `"tokens"`. Use it for any limitless numeric row. A spend day carries dollars and tokens; Codex credits carry dollars and a count. The widget picks what to show (cost, tokens, or both) through its descriptor, and formatting happens at the display edge, so the menu bar never re-parses a string.
- **`.badge`**: a short status pill, like `Disabled` or a pay-as-you-go cap. Use it for state, not a number.
- **`.chart`**: dated numeric points for a usage-trend row.
- **`.text`**: a string notice preserved in the local API. It does not render a widget. Use `.progress`, `.values`, `.badge`, or `.chart` for every descriptor-backed row.

Set the snapshot's `plan` when the provider exposes a plan name. On failure, return `ProviderSnapshot.error(provider:error:)` with a typed provider error when possible, so its friendly description reaches the user. Use the message-only factory only when there is no typed error. Never return stale or empty data silently.

## Steps

1. **Check first.** Look at open issues and `docs/providers/` to see if the provider is already requested or in progress.
2. **Create the module.** Add `Sources/Runway/Providers/<Name>/` with the auth store, usage client, and mapper. Implement both `refresh()` and `hasLocalCredentials()` (there is no default). The probe must stay local-only and reuse the same auth-store loaders and usability filters that `refresh()` uses. Do not write a second credential-reading path. Reuse the helpers in `Support/` (`ProviderParse` for JSON, number, and percent parsing, `RunwayISO8601` for timestamps).
3. **Declare its widgets.** Expose the provider's metrics as `WidgetDescriptor`s using the factories in `WidgetDescriptor+Factories.swift` (`percent`, `boundedDollars`, `boundedCount`, `spendTiles`, `dollarBalance`, `combined`, `values`, `badge`, and so on).
4. **Register it.** Add the provider to the list in `AppContainer`.
5. **Test it.** Add tests under `Tests/RunwayTests/`, including a mapper test that feeds a sample API response and checks the resulting metric lines.
6. **Document it.** Add a page under `docs/providers/` covering what it tracks, where its credentials come from, the endpoints it calls, and what its error states mean.
7. **Run it.** Build and launch with `./script/build_and_run.sh` and confirm the provider shows up.

## Conventions

- Validate only at the boundary (the API response). Trust the app's internal types.
- Match the metric labels and units the provider's own dashboard uses.
- Declare the provider's quick links on its `Provider` value (`links:`). Each `ProviderLink(label:url:)` renders as a button in the card's expanded area and opens in the default browser. Ship the provider's Status, Console, or Dashboard pages where they exist. Leave `links` off for providers without any. At most two links per provider, with standard labels (Status, Dashboard, API Keys, or Usage). Only `http(s)` URLs with a non-empty label render.

## User-supplied API keys

A provider with nothing local to read (OpenRouter, Z.ai) conforms to `APIKeyManaging` so the **Settings → API Keys** card manages its key with no per-provider UI work:

- The auth store exposes a four-state `keyStatus()` (`notSet`, `fromEnvironment`, `saved`, `overrideActive`), a `currentAPIKey()` for the reveal toggle, and `saveAPIKey(_:)` and `deleteAPIKey()` that write to a config file the auth store already reads. Because the config file takes precedence over the env var, a saved key is an override.
- The provider delegates those to its auth store and reports its storage path and env name for the card's copy.
- `AppContainer` collects every `APIKeyManaging` provider into `apiKeyProviders`, which the card lists.

Persist the key to a file the auth store already checks, so the file stays the source of truth and a user can edit it by hand.
