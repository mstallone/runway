# Releasing

Releases are automated. When you push a stable tag such as `v0.7.1` on `main`, the pipeline tests, builds, signs, notarizes, and publishes a new version with its SHA-256 checksum. Prerelease suffixes are rejected. The macOS pipeline is [.github/workflows/release.yml](../.github/workflows/release.yml), which calls the [iOS TestFlight pipeline](../.github/workflows/release-ios.yml) in parallel. The step-by-step is in the `release-swift` skill.

Release tags are owner-managed. See [CONTRIBUTING.md](../CONTRIBUTING.md). Everything below is one-time setup for the maintainer's fork, not something contributors need.

## Release setup (one-time)

The release workflow needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | base64 of the Runway Developer ID Application `.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12` |
| `APPLE_NOTARY_PRIVATE_KEY_BASE64` | base64 of an App Store Connect API private key (`.p8`) |
| `APPLE_NOTARY_KEY_ID` | the App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | the App Store Connect API issuer ID |
| `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` | base64 Developer ID provisioning profile for the production iCloud container |
| `SPARKLE_PUBLIC_KEY` | base64 EdDSA public key, baked into the build as `SUPublicEDKey` |
| `SPARKLE_PRIVATE_KEY` | base64 EdDSA private key used to sign the DMG |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | base64 of the Apple Distribution `.p12` that signs the iOS app |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12` |
| `APPLE_IOS_APP_STORE_PROFILE` | base64 App Store provisioning profile for the iOS app |
| `APPLE_IOS_WIDGET_APP_STORE_PROFILE` | base64 App Store provisioning profile for the iOS widget extension |

### macOS signing and notarization

Export the Developer ID Application cert (with its private key) from Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 | pbcopy`. Create an App Store Connect API key with the **App Manager** role (it notarizes the Mac app and uploads the iOS app), download its `.p8` once, and base64-encode it the same way. The certificate, API key, and iCloud profile must all belong to the same team (`8KZBNZJBAX`). Generate the Sparkle EdDSA key pair once with Sparkle's `generate_keys` tool. The public and private values must be a matching pair, or signing is silently skipped.

### iOS signing

The iOS TestFlight jobs sign manually with the `APPLE_DISTRIBUTION_*` cert and the two `APPLE_IOS_*_PROFILE` secrets (one App Store profile per bundle ID: the app `com.mattstallone.runway.mobile` and the widget extension `com.mattstallone.runway.mobile.widgets`), and reuse the three `APPLE_NOTARY_*` secrets for the upload and TestFlight API calls. Xcode cloud signing is not used, because an App Manager API key cannot access cloud-managed distribution certificates ("Cloud signing permission error").

You can create the Apple Distribution certificate and App Store profiles through the App Store Connect API with the App Manager key: generate an RSA-2048 CSR, `POST /v1/certificates` with type `DISTRIBUTION`, then `POST /v1/profiles` with type `IOS_APP_STORE` referencing the bundle ID and certificate, once per bundle ID. Package the cert and private key as a `.p12` **with OpenSSL 3's `-legacy` flag** (the modern defaults produce a `.p12` that macOS `security import` rejects with "MAC verification failed") and include the WWDR G3 intermediate. Store the `.p12`, its password, and the profiles in 1Password with the other signing material.

### App Store Connect

Create the app record (My Apps → New App, iOS, bundle ID `com.mattstallone.runway.mobile`, any unique SKU), and add an internal TestFlight tester group with **automatic distribution** so every uploaded build reaches internal testers without a manual step. The App ID must already have the CloudKit capability with both Runway containers (see [iOS app](ios-app.md)).

The iOS jobs only run when the release needs them. The iOS Gate job skips Mac-only releases (no iOS-relevant changes since the last build the external testers received) unless that build is nearing its 90-day expiry. See [iOS app](ios-app.md#releasing-testflight). For external testers, the TestFlight External job submits each shipped release for Beta App Review, and testers receive it when Apple approves. The job runs in the **iOS TestFlight** GitHub environment, so the repository's Deployments panel shows the public join link (https://testflight.apple.com/join/uA4aHUEx) next to the Update Feed deployment. Its one-time setup has two steps. First, create an external group named `External` under TestFlight → External Testing, and add testers by email or enable a public link (the workflow's `TESTFLIGHT_EXTERNAL_GROUPS` env lists the group names it ships to). Second, fill in the app's TestFlight **Test Information**: the beta app description, the feedback email, and the review contact and sign-in details the first submission asks for. The app needs no demo account because it reads the tester's own iCloud data. Mark it as not requiring sign-in and say so in the review notes.

### iCloud Sync

Store the original development and Developer ID provisioning profiles in 1Password as secure documents. Install the development profile on each registered Mac. Base64-encode the Developer ID profile and store it only in the `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` Actions secret. See [iCloud Sync](icloud-sync.md#development-and-release-setup) for the container identifiers, build command, and inspection command.

### GitHub Pages and the domain

The repository must be public (Sparkle fetches the DMG and appcast anonymously), and the update feed is served through GitHub Pages. Set Settings → Pages → Build and deployment → Source to **GitHub Actions**. The publishing workflows create and maintain the `update-feed` branch and deploy through the **Update Feed** environment. The landing page ships the same way: `website/` on `main` is published to `update-feed` by `.github/workflows/landing-page.yml` on merge, alongside the appcast and pricing supplement.

The Pages site carries the custom domain **runway.page** (Settings → Pages → Custom domain, with Enforce HTTPS on; DNS is four A records on the apex plus a `www` CNAME to `mstallone.github.io`). GitHub serves the old `mstallone.github.io/runway/…` paths as redirects to `runway.page`. Shipped apps still poll the `mstallone.github.io` feed URL through that redirect, so never let the domain lapse or detach without first shipping a release that changes `SUFeedURL`. See [Updates](updates.md#where-updates-come-from).
