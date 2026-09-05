# Debugging and Capturing Logs

How to run a local build and watch what the app is doing.

## Run a local build

From the repo root:

```sh
./script/build_and_run.sh          # build and launch the dev app from dist/
./script/build_and_run.sh build    # build and stage only, don't launch
./script/build_and_run.sh verify   # launch and confirm the process is running
```

The script builds a signed app bundle under `dist/` and launches it in place. Nothing is installed to `/Applications`. The dev build has its own bundle id (`com.mattstallone.runway.dev`), so it keeps its own settings and keychain and never disturbs a released Runway. It has no update feed, so it never checks for updates. Test updates with a real signed, notarized release build.

The script launches the app without any `CLAUDE_CONFIG_DIR` or `CODEX_HOME` values inherited from the shell, and clears the dev app's persisted shell-environment snapshot first. This keeps an agent session's sandboxed homes (Claude Code and Codex export those variables) out of the dev app's Claude and Codex data. To test a custom home on purpose, launch with `KEEP_PROVIDER_HOMES=1`.

## Stream logs

To watch the app's logs live while you reproduce an issue:

```sh
./script/build_and_run.sh logs
```

This launches the dev app and streams its unified logs. It is equivalent to:

```sh
log stream --info --style compact --predicate 'process == "Runway"'
```

To read logs after the fact, use `log show` with a time window:

```sh
log show --last 10m --info --predicate 'process == "Runway"'
```

## Log file

The app also writes a file log to `~/Library/Logs/Runway/Runway.log`. This is what to send with a support report. It is capped at about 10 MB with one `.1` archive. Raise the detail in **Settings → Advanced → Log Level** (use **Debug** for full detail), then grab the file with **Copy Log Path** or **Reveal in Finder**. See [Logging](logging.md).

## Account log lines

The launch-time account pass (which account is signed in at the Claude and Codex default home) leaves a short trail in the log file:

- `accounts: claude default identity resolved (claude@<hash>)`: the default login named its account. The hash is derived from the account id, so two launches by the same account match.
- `accounts: codex default identity unresolved — …`: a login exists but its account cannot be named with certainty this launch (for example, an auth file without an account id, or an unbound account-scoped keyring credential). The card still works, but that source cannot take part in account-aware features until its identity is verified.
- `discovery: codex candidate ~/.codex-work: accepted (<hash>, auth.json)`: a custom Codex home supplied a usable, account-named OAuth login and takes part in an account card.
- `discovery: codex candidate ~/.codex-work: keyring identity unverified → hidden until its exact item is bound`: the home uses account-scoped keyring storage, but launch discovery has not yet associated that item with its account.
- `discovery: bound Codex keyring identity for home <hash>; card appears next launch`: a user-attended Refresh All read that exact item and recorded a fingerprint-bound account association.
- `discovery: codex candidate ~/.codex-work: accepted (<hash>, verified keyring)`: the keyring item still matches the verified binding and takes part in an account card.
- `discovery: codex candidate ~/.codex-work: OAuth credential names no account → skipped`: the home has a token but no account identity, so Runway does not guess from its path.
- `accounts: codex card codex@<hash> from 2 home(s)`: the account card was assembled from that many same-account Codex homes.
- `stale account cache discarded for claude`: the account at the default home changed between launches, so the previous account's cached snapshot was dropped.
- `account identity read skipped for claude, codex: login shell cold and no shell-environment snapshot exists yet`: the login-shell capture failed on a launch with no persisted snapshot, so those families were left unread rather than assembled from the wrong home.

## Profile the UI

`script/profile_ui.sh` measures popover performance end to end. It builds and stages the dev app, relaunches it with `RUNWAY_UI_PROFILE=1`, and an in-app driver walks the popover through scripted phases: a cold open, twelve warm open/close cycles, ten screen switches, ten caret toggles, a forced refresh with the panel open, and an idle soak. The script prints per-phase stats from the log: open latency split into layout and order-front, close cost, and main-queue stalls.

Run it before and after any change to the popover render path and compare. Reference numbers on Apple Silicon (August 2026): warm open in the low tens of milliseconds to first frame, and few or no stalls in the warm-cycles phase.

`RUNWAY_UI_PROFILE` is inert in normal use. No timing code runs without it. The stall watchdog measures how long async main-actor work waits (main-queue latency), which is a proxy for responsiveness, not a dropped-frame count.

The "cold open" measures the shipped first-click experience, which includes the launch pre-warm (it runs at +2s, before the driver's first open at +6s). To measure the true cold path with no pre-warm, launch with `RUNWAY_UI_PROFILE_COLD=1` as well.

## Profile the Memory window

`script/profile_memory_ui.sh` is the same harness for the Memory Explorer. It relaunches the dev app with `RUNWAY_UI_PROFILE_MEMORY=1`, and the driver walks the window through a cold open with the initial scan, six close/open cycles (each rebuilds the store), twelve file-document selection switches, six database-row loads, three re-scans, and an idle soak. Run it before and after any change to the Memory window's render or load paths.

Reference numbers on Apple Silicon (August 2026): a warm open builds the window in about 20ms and the scan lands about 20ms later. A re-scan with the window open is under 20ms (an unchanged Codex database re-lists from cache in under 1ms). Selecting a file document loads in under 10ms and a database row in under 20ms. The selection, database, and idle phases report zero main-queue stalls. Each open pays one or two 60ms stalls for the SwiftUI tree mount, which overlaps the window appearing.

## Tips

- **A provider shows an error.** Reproduce with `logs` running, then check that provider's page in `docs/providers/` for what its error states mean and where it reads credentials.
- **Nothing updates.** Refresh runs on a timer and respects the cache. See [Refreshing & caching](refreshing.md). Use the per-provider "Refresh" in the row's context menu to force one.
- **Keychain prompts on every rebuild.** The script signs with a stable Apple Development identity so the permission ACLs stick. An ad-hoc-signed build (a bare `swift build` binary, or the script's fallback when no identity is installed) cannot hold a durable approval, because its identity is the binary's own hash, so every rebuild would prompt again. Runway therefore refuses to open keychain approval dialogs from ad-hoc builds: keychain-backed providers stay on the Connect state, and the log says why (`interactive keychain read refused`). If Connect seems to do nothing in a dev build, make sure an Apple Development identity exists in your keychain.
- **Inspect the local API.** With the app running, `curl 127.0.0.1:6736/v1/usage` shows the same snapshots the UI uses. This helps tell a fetching or mapping problem from a UI problem.
