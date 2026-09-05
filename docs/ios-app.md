# iOS Companion App

RunwayMobile (in `ios/`) is a read-only iPhone and iPad viewer for the usage your Macs publish through [iCloud Sync](icloud-sync.md). It holds no provider credentials and never writes to iCloud. It fetches every device record from Runway's private CloudKit database and renders it.

The dashboard shows:

- **Across Your Macs**: Today, Yesterday, and Last 30 Days spend and token tiles plus a usage trend, summed per day from every device's history (the same additive model the Mac uses).
- **One section per Mac**: that device's live snapshot, one collapsed row per provider showing the account name, its plan, and the percent of the weekly quota still left (blank for providers with no weekly meter). Expanding a row shows its metrics (quota meters with reset countdowns, spend tiles, status badges, charts), warnings, and refresh errors. The record's age sits in the section header. A Mac whose Keychain login is waiting to be connected shows the same muted key glyph the Mac uses, since only that Mac can load it.

Data refreshes on launch, on returning to the foreground, and with pull-to-refresh. Liveness is bounded by the Macs' five-minute publish cadence.

## Widgets

The app ships lock screen and home screen widgets ("Across Your Macs") with the combined totals: Today on every family, plus Yesterday, Last 30 Days, and the usage trend where the size allows. Lock screen families are the inline line, the circular Today tile, and the rectangular Today/30 Days list. Home screen families are small and medium.

Each widget can show cost (the default: dollars when priced, token counts when not) or token counts. Long-press the widget and choose Edit Widget (on the lock screen, tap the widget while customizing), so one slot can show spend while another shows tokens.

The widget extension reads the same CloudKit data on WidgetKit's schedule (roughly every half hour), and the app asks widgets to reload whenever it fetches fresher data in the foreground. The widget caches the last good numbers, so a failed refresh shows slightly stale totals instead of an empty widget. Cached entries show their fetch age, and day tiles re-anchor to the current date, so a cached "Today" never labels an older day. The cache is tied to the iCloud account and cleared on sign-out. Incomplete totals are never silent: a warning triangle appears when payloads were unreadable or models unpriced, and an all-unreadable container says "Update this app". Signed-out, restricted, waiting-for-first-sync, and unreachable states each show a short notice instead of numbers.

## Wire contract

The app decodes the versioned payloads the Mac writes (`runway.history.v2`, `runway.snapshot.v1`) with tolerant decoders in `ios/Shared/SyncWire.swift` (shared with the widget extension, alongside the CloudKit reader in `UsageSyncReader.swift`). Unknown JSON keys and unknown row types are ignored, so additive Mac-side changes do not break older phones. A schema bump shows an "update Runway and this app" notice instead of wrong numbers. When the Mac payloads change shape, update `SyncWire.swift` to match.

## Building

Open `ios/RunwayMobile.xcodeproj` in Xcode and run, or:

```bash
xcodebuild -project ios/RunwayMobile.xcodeproj -target RunwayMobile \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

That unsigned simulator build is for compile verification only. A launch aborts at CloudKit setup because it carries no iCloud entitlements. Run the app from Xcode instead, which signs simulator and device builds.

Debug builds read the development container (`iCloud.com.mattstallone.runway.dev`, Development environment, the same place dev Mac builds write). Release builds read the production container. The app and widget App IDs (`com.mattstallone.runway.mobile` and `com.mattstallone.runway.mobile.widgets`) both need the CloudKit capability with both containers. Signing is automatic with the development team. On device, the app must be signed into the same iCloud account as the Macs.

## Releasing (TestFlight)

The iOS app ships from the same `v*` tag as the Mac app, when the release touches it. The release workflow calls `.github/workflows/release-ios.yml`. Its "iOS Gate" job (`script/testflight_gate.mjs`) checks what changed since the last build the external TestFlight testers received. A Mac-only release skips the iOS jobs, because every upload is a new version that goes through a fresh Beta App Review and pushes an update at testers. When the gate says ship, the "iOS TestFlight" job archives the app, signs it, and uploads it to App Store Connect, which serves it to internal testers once Apple finishes processing. The "TestFlight External" job then waits for that processing, adds the build to the external tester group(s), and submits it for Beta App Review (`script/testflight_distribute.mjs`). External testers receive it when Apple approves. Testers install and update through the TestFlight app. There is no Sparkle feed on iOS and no notarization.

The gate ships when anything under `ios/`, the iOS release workflow, or a TestFlight pipeline script changed since the baseline build. Changes to the macOS release job do not count. The baseline is the newest processed build present in every external TestFlight group. Its version names the tag it was built from, so a failed upload or failed external distribution never advances the baseline. The gate also ships when the baseline build is older than 60 days, because TestFlight builds expire 90 days after upload. Beta App Review approval is not part of the baseline: it stays pending for up to a day after every ship, and waiting for it would re-submit identical builds. TestFlight can therefore lag the Mac version (say, 0.8.9 on the Mac while TestFlight shows 0.8.5). That is expected. A Mac-side change that matters to the phone must update the wire decoders in `ios/`, which trips the gate. To ship iOS regardless, run the Release workflow manually with the `force_ios` input checked.

- The version is the tag (`v0.7.1` → `0.7.1`) and the build number is the git commit count, both injected at build time. `MARKETING_VERSION` in the Xcode project is never bumped by hand. TestFlight rejects a reused build number for the same version, so rerunning a tag that already uploaded fails at the upload step. Tag a new patch version instead.
- Signing is manual: an Apple Distribution certificate and two App Store provisioning profiles (one for the app, one for the widget extension) stored as repository secrets, the same pattern as the Mac release's Developer ID cert and iCloud profile. The App Store Connect API key (App Manager role) only authenticates the upload and the TestFlight distribution calls. Cloud signing does not work with API keys below Admin.
- `script/release_ios.sh` is the whole build. Run it locally with `SKIP_TESTFLIGHT_UPLOAD=1` to get a signed `.ipa` in `dist/ios/` without uploading.
- The upload can never be repeated, but the external-distribution job is idempotent. If it fails (say, before the one-time Test Information is filled in), rerun just that job with `gh run rerun <run-id> --failed`. The uploaded build is untouched.

The one-time App Store Connect setup (app record, tester group, key role) is in [Releasing](releasing.md).
