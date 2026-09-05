# Runway Documentation

What the app does and how it behaves. These pages describe behavior, not visuals. If the app and a page disagree, that is a bug.

## The app

- [Dashboard](dashboard.md): the popover, rows, toggles, reordering, keyboard shortcuts
- [Menu bar](menu-bar.md): pinning metrics to the menu bar
- [Settings](settings.md): every option and what it changes
- [Memory Explorer](memory-explorer.md): view and edit each AI harness's memory and instruction files
- [Refreshing and caching](refreshing.md): when data updates and what happens when a fetch fails
- [iCloud Sync](icloud-sync.md): how spend history is combined across Macs
- [iOS companion app](ios-app.md): the iPhone and iPad viewer for synced usage
- [Model pricing](pricing.md): how spend tiles price tokens and where the rates come from
- [Updates](updates.md): automatic updates and manual checks
- [Privacy](privacy.md): what stays local and which optional services send data

## Integrations

- [Command-line interface](cli.md): one-shot usage reads for agents and scripts
- [Local HTTP API](local-http-api.md): read usage from other apps on `127.0.0.1:6736`
- [Proxy](proxy.md): route provider requests through SOCKS5 or HTTP(S)

## Providers

What each provider tracks, where its credentials come from, and what its errors mean.

- [Antigravity](providers/antigravity.md)
- [Claude](providers/claude.md)
- [Codex](providers/codex.md)
- [Copilot](providers/copilot.md)
- [Cursor](providers/cursor.md)
- [Devin](providers/devin.md)
- [Grok](providers/grok.md)
- [Kimi](providers/kimi.md)
- [Muse](providers/muse.md)
- [OpenCode](providers/opencode.md)
- [OpenRouter](providers/openrouter.md)
- [Sakana Fugu](providers/sakana.md)
- [Z.ai](providers/zai.md)

## For developers

- [Architecture](architecture.md): composition root, stores, the provider pipeline, the AppKit bridge
- [Adding a provider](adding-a-provider.md): the metric contract and the register, test, and document steps
- [Debugging and logs](debugging.md): running a local build and streaming logs
- [Logging](logging.md): the file log, log levels, subsystem tags, and what is never logged
- [Releasing](releasing.md): the release pipeline and its one-time setup (maintainer only)
