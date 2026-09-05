# Logging

Runway keeps a file log so you can see what the app was doing and share it with support. Lines at or above your chosen level also go to the macOS unified log, so raising the level to Debug adds detail in both places (see [Debugging](debugging.md) for `log stream`).

## Where the log file lives

```
~/Library/Logs/Runway/Runway.log
```

The easiest way to grab it: open Settings → Advanced and use **Copy Log Path** or **Reveal in Finder**.

## Changing the log level (Settings → Advanced)

The **Log Level** picker controls how much detail is written. Your choice persists across launches and takes effect immediately.

| Level | What it captures |
|---|---|
| Error | Only failures. |
| Warning | Failures plus things that looked wrong but recovered. |
| Info | Refresh start and end, per-provider results, cache and auth milestones. |
| Debug | Everything, including per-request and per-cache-check detail. |

The release default is **Info**. Turn on **Debug** only while reproducing a problem. It is much noisier.

If a local usage log exists but cannot be read, Runway writes one warning and skips it for that refresh. It warns again only if the file recovers and later becomes unreadable again.

Any provider refresh that takes 10 seconds or longer writes a Warning-level `[refresh]` line with the provider ID, elapsed milliseconds, and threshold. This is visible at the default Info level, so a slow log scan or network call can be found in a normal support log. The warning is diagnostic only. Other provider cards still update independently, and the slow provider is allowed to finish.

## Subsystem tags

Every line starts with a bracketed tag so the log is easy to grep:

`[refresh]` `[cache]` `[http]` `[auth]` `[keychain]` `[menubar]` `[updates]` `[config]` `[subprocess]` `[localapi]`, plus per-provider tags like `[plugin:claude]` and `[auth:claude]`.

To follow just the refresh cycle:

```sh
grep '\[refresh\]' ~/Library/Logs/Runway/Runway.log
```

## What is never logged

Secrets never reach the log. The app redacts access and refresh tokens, cookies, session tokens, and API keys before it writes any line. A sensitive value becomes `first4...last4`, or `[REDACTED]` when it is too short to mask safely. Paths under your home directory become `[PATH]`. The app never logs a full response body. On an HTTP error it can record a redacted, truncated preview of at most 500 bytes at Debug. A test suite guards the redaction rules.

## File size cap

The log is capped at about 10 MB. When it fills, the app rotates the current file to `Runway.1.log` and starts a fresh `Runway.log`. A long session uses at most about 20 MB across the live file and one archive. If a previous session left an oversize file, the app rotates it once at launch.

> Note: the dev build and a released build both write to the same `Runway.log`. Running both at once interleaves their lines.
