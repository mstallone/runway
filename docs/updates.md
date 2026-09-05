# Updates

Runway updates itself with [Sparkle](https://sparkle-project.org), the standard update framework for Mac apps. The app downloads updates from Runway's own release feed and verifies them before they install.

## How it works

- **Automatic checks.** The app checks for a new version in the background about once an hour. When one is found, an **Update Available** banner appears at the top of the popover. Click **Install Update** to open the update window (release notes, download, install). The banner's close button snoozes it until the next time the app finds the update.
- **Manual check.** Open **Settings → Advanced → Updates** and click **Check for Updates…**. For manual checks and banner installs, Runway brings itself to the foreground before opening Sparkle so the update window is not buried behind another app. Because Runway normally lives only in the menu bar, it briefly shows a Dock icon for the update session, then hides it again.
- **Turn it off.** The **Update Automatically** switch in **Settings → Advanced → Updates** stops the background checks. You can still check manually.

![Stable-only update settings](assets/updates-stable-only.png)

## Where updates come from

Runway publishes update builds on its GitHub releases and serves the list of versions (the appcast) from `https://mstallone.github.io/runway/appcast.xml`. That address is baked into every shipped app. Today it redirects to `https://runway.page/appcast.xml`, the same GitHub Pages site as the [runway.page](https://runway.page/) landing page. While the redirect is in place, the feed depends on the domain, so keep `runway.page` registered and working. If the domain must ever go away, detach it in the Pages settings so the `mstallone.github.io` address serves the feed directly again. Never leave a dead domain configured.

Each download is signed two ways, Apple notarization plus Runway's own Sparkle signature, and the app refuses anything that does not match. Updates are only available in the official signed release build, not in local developer builds.
