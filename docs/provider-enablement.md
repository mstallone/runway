# Which Providers Are On

How Runway decides which providers start on and what happens when an update adds a new provider. The one rule: your own toggles always win and are never overridden.

## First install

A fresh install starts with Claude, Codex, and Cursor. It then checks which providers have credentials on your Mac: an existing local login, a saved API key, or a supported environment variable. The check is local. Nothing leaves your Mac. The app then switches to exactly the set it found. If it finds nothing, the Claude, Codex, and Cursor starter set stays. If the app closes before this setup starts, it resumes on the next launch. All providers are checked at once, so detection takes as long as the slowest single check. When the check turns a provider on, Runway fetches it right away. See [Dashboard § First launch](dashboard.md#first-launch) for how the dashboard presents this.

## When an update adds a new provider

On the first launch after an update, Runway compares the providers it now ships with the ones this install has seen before. For each new one, it runs the same local credential check:

- **Credentials found**: the provider turns on and appears on the dashboard.
- **No credentials**: it stays off. You can turn it on later in **Customize**.

This check happens once per provider. After that, the provider is yours to manage. If you turn it off, no update turns it back on. If you install the tool later, that does not flip it on either. Use Customize when you want it.

## Your choices stick

Everything you set in Customize (providers on or off, metric layout, menu-bar stars) carries across updates. The only change an update can make is to turn on a provider you have never seen before, and only when you have that tool installed.

The one exception is **Reset All Customization** at the top of the Customize provider list. It re-runs the same credential detection as first launch and switches the enabled set back to exactly the providers with credentials on your Mac (Claude, Codex, and Cursor if it finds none). So it can turn a provider off even if you had it on, or on if you had turned it off. It asks for confirmation first. See [Dashboard](dashboard.md) for the metric side of that reset.

## How it works

The app persists three small lists in its settings:

- **Enabled providers**: the providers currently on. The dashboard and menu bar read this.
- **Known providers**: every provider this install has ever seen. This is what separates "new in this update" from "you turned it off". A provider missing from the enabled list but present in the known list is your choice, and the app leaves it alone. Only providers missing from both get the credential check, and the app marks each one known right away so the check never repeats.
- Each provider implements a cheap, local-only credential probe (`hasLocalCredentials()`) that checks the same files, keychain entries, saved keys, and environment variables its normal refresh reads, never the network.

Older installs (from before first-run detection existed) started with every provider on and stored only the ones turned off. A one-time settings migration converts them to the lists above with the same providers on and off as before. Nothing visibly changes on the launch that migrates. Those installs then join the same new-provider detection.
