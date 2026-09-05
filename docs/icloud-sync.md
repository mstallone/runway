# iCloud Sync

**Sync Across Macs** is on by default. You can turn it off in Settings. While it is on, each device keeps one record in Runway's private CloudKit database, part of your own iCloud account, and reads the records written by your other devices. Runway keeps a random device ID in its private Application Support data, so the same Mac keeps updating its existing record after you reset preferences or reinstall. There is no folder picker, pairing code, or separate account.

Upgrades from either older Keychain-backed device-ID format copy the saved ID into the current file without reading a Keychain secret. If both that saved copy and the current file are missing, Settings pauses publishing and offers **Recover Identity**. That action may show a macOS Keychain approval dialog. Automatic sync never requests the legacy value.

Each device's record has two parts:

- **History**: normalized daily tokens and spend, model totals, and unknown-model names for sources that are local to one Mac (Claude, Codex, Grok, Muse, Sakana, and OpenCode). Macs merge these into the combined view. Cursor's history is already account-wide, so it is never added across Macs.
- **Snapshot**: that device's latest rendered usage state for every enabled provider (current quotas, plans, balances, reset times, and refresh errors), with card titles as the dashboard shows them, including your renames. Macs never display other Macs' snapshots. This part exists for companion apps (such as the iOS app) that show live usage without holding any provider credentials.

Records never contain credentials, raw logs, or raw provider responses. When you disable a provider, Runway removes its peer contributions from the combined view and omits it from this device's next record. Its local cached snapshot remains.

Runway combines the valid history payloads in memory and rebuilds Today, Yesterday, Last 30 Days, Usage Trend, unknown-model warnings, and model breakdowns. The same combined spend rows feed the dashboard, Total Spend, menu-bar pins, share cards, and the local HTTP API. Quotas, plans, balances, and provider errors stay this Mac's own values. Rows in an older peer record are ignored once they fall outside the calendar window the local history scanners use.

Every device only writes and deletes its own record, so records cannot conflict. Readers fetch the whole zone and rebuild the peer set from scratch, so a device that stops syncing disappears on the next load.

This Mac updates its record after a five-minute refresh batch, a manual refresh, or a provider enablement change, and checks for peer updates at the same moments plus on a five-minute poll. CloudKit delivery is usually a matter of seconds, but it is eventually consistent. An offline Mac catches up when it comes back.

## Multiple accounts across Macs

Histories match by **account**, not by card name. Each device's record notes which account every card belongs to (an opaque account or organization identifier, never an email), so the same account merges into the same card everywhere, even when one Mac shows it as the main card and another as an extra account card.

An account you use on another Mac but have no login for here does not become a card. It appears as its own slice in **Total Spend**, named by its account code ("claude@ab12cd34"), so the number at the top covers all your Macs. That code is the same id the account's card carries on any Mac it is signed in on. When you log that account in locally, its card appears under that same id with the cross-machine history attached.

If a synced record cannot identify the account behind a main Claude or Codex card, Runway keeps its spend in one remote family slice instead of attaching it to a different local account or dropping it from Total Spend.

Devices running an older Runway read their own format but report this device's newer record as "update Runway". Update both sides to sync multi-account machines.

Settings lists each valid device record with the time that device generated it. To remove a device from the combined summary, turn sync off on that device. This deletes its record from iCloud, stops that device from reading peers, and returns every surface there to local-only spend. Malformed records are ignored and reported in Settings and the app log.

## Development and release setup

Apple requires the iCloud container assignment in the provisioning profile embedded in the app, and the App ID must have the CloudKit capability. Runway uses separate containers so development builds cannot write production data:

- `com.mattstallone.runway.dev` uses `iCloud.com.mattstallone.runway.dev`.
- `com.mattstallone.runway` uses `iCloud.com.mattstallone.runway`.

Development-signed builds also run against the container's **Development** CloudKit environment (release builds use **Production**), so a dev build never touches shipped data even inside the same container.

CloudKit creates the `UsageHistory` zone, the `DeviceUsage` record type, and its `history` and `snapshot` fields the first time a development build writes, but only in the Development environment. Production schemas are never auto-created. Before the first release that ships sync, and after any schema change (a new record type or field), open the CloudKit Console for the production container and use **Deploy Schema Changes** to promote the Development schema to Production. A release build pointed at an undeployed Production container fails its first write with the CloudKit error in Settings and the app log.

Create a `MAC_APP_DEVELOPMENT` profile that includes every registered development Mac and a `MAC_APP_DIRECT` profile for releases. Install the development profile on each included Mac. The development build selects the newest non-expired profile matching the development bundle and iCloud container from Xcode's profile directory or the legacy MobileDevice directory:

```bash
./script/build_and_run.sh
```

Set `ICLOUD_PROVISIONING_PROFILE=/path/to/profile.mobileprovision` only to override that selection. An explicit missing path fails the build instead of producing an app without iCloud access.

The release workflow reads the base64-encoded `MAC_APP_DIRECT` profile from the repository Actions secret `APPLE_DEVELOPER_ID_ICLOUD_PROFILE`. Keep the original provisioning profiles and signing `.p12` in a password manager, never in the repository.

To inspect the records written by a running build, use the CloudKit Console (<https://icloud.developer.apple.com>): pick the container, then **Data → Private Database → zone `UsageHistory` → record type `DeviceUsage`**, in the **Development** environment for dev builds. The same query works from the command line once `xcrun cktool save-token` has stored a token:

```bash
xcrun cktool query-records \
  --container-id iCloud.com.mattstallone.runway.dev \
  --environment development --database-type private \
  --zone-name UsageHistory --record-type DeviceUsage
```

No record is expected when sync is off, the app is signed without the matching profile, or the first write has not completed. The Settings error and app log distinguish those cases, including a Mac not signed into iCloud. The spinner only appears while a read or write is in progress.
