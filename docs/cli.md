# Command-Line Interface

Runway ships a one-shot `runway` command for agents and scripts. It prints the [`/v1/limits`](local-http-api.md#get-v1limits) JSON and exits. It never launches or leaves the menu-bar app running. The output contains scalar limits and balances, not UI rows, colors, subtitles, charts, or spend-history tiles.

```sh
runway                 # every enabled provider, refreshing stale cache entries
runway codex           # one provider, refreshing when its cache is stale
runway codex --force   # refresh through the shared provider engine, cache, print, exit
```

The command and the app share the same providers, auth stores, pricing, refresh coordinator, and snapshot cache. A normal read reuses snapshots less than five minutes old and refreshes missing or stale ones. `--force` skips that freshness check and writes successful results to the same cache.

`--force` is not a full substitute for the app's manual refresh. Nobody is watching a terminal command, so it never opens a macOS Keychain approval dialog. It also cannot inherit one: `runway` is a separate executable with its own signature, and macOS grants Keychain access per binary. A provider whose credential lives only in a protected Keychain item still works through the snapshot the app writes, within its five-minute freshness window. A forced or stale read of that provider reports it as unavailable. Credentials never appear in the output.

A provider argument matches by plain string comparison, the same as the [local HTTP API](local-http-api.md). An exact provider ID names that provider. A family ID (`claude`, `codex`) names every account card of that family. With one account, the family ID names that one card. The output contains every matched provider. An ID that names nothing exits with an error.

## Install on `PATH`

In Runway, open **Settings → Advanced → Command Line** and click **Install…**. After the macOS administrator prompt, `runway` is available in new terminal sessions. The installed symlink points to the signed helper inside Runway, so app updates also update the command.

Exit codes: `0` success, `2` invalid arguments or unknown provider, `4` refresh or local read failed.
