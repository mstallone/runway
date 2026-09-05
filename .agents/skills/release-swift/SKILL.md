---
name: release-swift
description: "Cut a stable release of Runway (Swift menu-bar app): pick a version, generate a categorized changelog, tag from `main`, and publish the GitHub Release with notes."
---

# Release Swift

Pushing a `v*` tag on `main` runs `.github/workflows/release.yml`. It builds, signs, notarizes, attaches `Runway-<version>.dmg` to the GitHub Release, and updates the Sparkle `appcast.xml` on `update-feed`. The same run's **iOS Gate** job (`script/testflight_gate.mjs`) decides whether this tag ships the iOS companion app. It skips Mac-only releases (no iOS-relevant changes since the last build distributed to the external TestFlight group, and that build under 60 days old). When it ships, the **iOS TestFlight** job builds and uploads the iOS app, and the **TestFlight External** job adds the processed build to the external tester group and submits it for Beta App Review. CI creates the release with an empty body, so this skill generates the changelog, records it in `CHANGELOG.md`, and publishes the notes onto the release.

Runway has one release channel. Tags are `vMAJOR.MINOR.PATCH`. Suffixed prerelease tags are rejected. The tag is the version (`v0.7.1` becomes `CFBundleShortVersionString = 0.7.1`), and `CFBundleVersion` is the git commit count. There are no version files to bump.

## Cutting a release

### 0. Preflight: iOS signing assets

Only needed when the release will ship iOS: anything under `ios/` or the TestFlight pipeline changed since the last externally distributed build, that build is over 60 days old, or the run will use the `force_ios` input. For a Mac-only release, skip this step.

Check this before tagging. A profile problem fails the iOS job during signing, before the upload consumes the TestFlight build number, so it is recoverable on the same tag: fix the secret and `gh run rerun <run-id> --failed` (see step 7). Preflighting saves that round trip.

Both App Store profiles must exist and be `ACTIVE`:

- `Runway Mobile App Store` → `com.mattstallone.runway.mobile`
- `Runway Mobile Widgets App Store` → `com.mattstallone.runway.mobile.widgets`

Editing an App ID's capabilities silently invalidates every existing profile built on it. The profile flips to `INVALID` and signing fails later with an unrelated-looking error. If capabilities changed since the last release, regenerate both profiles and refresh `APPLE_IOS_APP_STORE_PROFILE` and `APPLE_IOS_WIDGET_APP_STORE_PROFILE` together.

Both App IDs must keep both iCloud containers enabled: `iCloud.com.mattstallone.runway` for Release and `iCloud.com.mattstallone.runway.dev` for Debug. A profile granting only one signs one configuration and breaks the other.

Verify a downloaded profile before trusting it:

```sh
script/decode_provisioning_profile.sh profile.mobileprovision /tmp/p.plist
/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers' /tmp/p.plist
/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' /tmp/p.plist
```

Expect both containers and both environments (`Production`, `Development`).

### 1. Choose the version

Propose the next version (default: patch bump) and get the owner's confirmation before going on.

### 2. Generate the changelog

Collect commits since the previous stable release and categorize each. The inherited history contains old beta tags, so do not use the nearest tag blindly. Span from the last plain stable tag (for example `v0.7.0...v0.7.1`).

| Commit prefix | Category |
|---|---|
| `feat`, `feature`, or starts with "Add" | New Features |
| `fix` or starts with "Fix" | Bug Fixes |
| `refactor`, `enhance` | Refactor |
| `chore`, `style`, `docs`, `perf`, `test`, `ci`, `build` | Chores |
| Uncategorized | Bug Fixes |

Author attribution is required on every entry:

- With a PR number `(#123)`, resolve the PR from the commit rather than assuming its repository:

  ```sh
  gh api "repos/mstallone/runway/commits/{full_hash}/pulls" \
    --jq 'map(select(.number == {pr}))[0] |
      if . == null then null else {url: .html_url, author: .user.login} end'
  ```

  Use the returned `url` and `author`. The endpoint returns fork PRs for commits merged in this repository, so overlapping PR-number namespaces are handled by commit provenance.
- Without a PR number: `gh api /repos/mstallone/runway/commits/{full_hash} -q '.author.login'`.
- If the PR lookup returns null, omit the PR link and use the commit attribution lookup. If that also returns null, use the git author name.

Output the changelog in a code block (template below) for review.

### 3. Owner approval

Wait for explicit approval of the changelog before changing any files. Accept edits if offered.

### 4. Record it in CHANGELOG.md

`main` is protected, so the changelog lands through a PR. Prepend the approved section right after the `# Changelog` header, then:

```sh
git switch main && git pull
git switch -c docs/changelog-v{version}
git add CHANGELOG.md && git commit -m "docs: changelog for v{version}"
git push -u origin docs/changelog-v{version}
gh pr create --base main --title "docs: changelog for v{version}" --body-file /tmp/pr-v{version}.md
```

Follow the PR description structure in AGENTS.md. Wait for CI, then squash-merge:

```sh
gh pr merge {pr} --squash --delete-branch
```

### 5. Tag the merged commit and push

Tag after the merge, so the tag points at a commit on `main`. Tagging first leaves the release tag off `main` forever (the squash-merge rewrites the commit), which pollutes the next release's changelog range.

```sh
git switch main && git pull
git tag -a v{version} -m "v{version}"
git push origin v{version}
```

Pushing the tag starts the release run. There is no `git push origin main` step.

### 6. Publish the notes

CI creates the release with an empty body. Attach the approved notes after it finishes:

```sh
gh run watch
gh release view v{version} >/dev/null 2>&1   # confirm CI created the release
gh release edit v{version} --notes-file /tmp/notes-v{version}.md
```

Never leave a release blank.

A failed first-release run is safe to rerun. If the GitHub Release for the current tag was published but the appcast was not, the workflow rebuilds the feed only when that tag is the fork's sole release. If older release history exists while `appcast.xml` is missing, it aborts rather than dropping prior Sparkle entries.

### 7. Verify (never leave a draft)

```sh
gh release view v{version} --json isDraft,isPrerelease,assets,body \
  --jq '{isDraft, isPrerelease, assets:[.assets[].name], bodyLen:(.body|length)}'
git fetch origin update-feed && git show origin/update-feed:appcast.xml | grep -F "Runway-{version}.dmg"
curl -s "https://mstallone.github.io/runway/appcast.xml" | grep -F "Runway-{version}.dmg"
```

The last check matters. Publishing is two hops: Release (or pricing-supplement) pushes `appcast.xml` to the `update-feed` branch, then `.github/workflows/deploy-update-feed.yml` on `main` deploys that branch to the live site (Pages source is "GitHub Actions"). The Release macOS job dispatches the deploy right after publishing the branch, with `workflow_run` completion as a fallback trigger. GitHub sometimes returns "Deployment failed, try again later" even though `update-feed` is correct. If the branch has the version but the live URL does not after about 10 minutes, check `gh run list --workflow=deploy-update-feed.yml` and re-run `gh workflow run deploy-update-feed.yml --ref main` (it must be `main`; the workflow file is not on `update-feed`). Sparkle clients only see the live URL.

Require `isDraft=false`, `isPrerelease=false`, the `Runway-<version>.dmg` and `Runway-<version>.dmg.sha256` assets, `bodyLen>0`, and the version in the appcast.

Also confirm the iOS jobs did what the gate decided (`gh run view` shows all jobs). **iOS Gate** must be green. Its log says SHIP or SKIP and why. If SKIP, the **iOS TestFlight** and **TestFlight External** jobs are skipped. That is the expected outcome for a Mac-only release. If SHIP:

- **iOS TestFlight** green means the build was uploaded. TestFlight pushes it to internal testers once Apple finishes processing (minutes).
- **TestFlight External** green means the processed build was added to the external group and submitted for Beta App Review. External testers receive it when Apple approves (hours to about a day; visible in App Store Connect → TestFlight). Nothing to babysit.

An iOS-only failure does not invalidate the Mac release. Fix the cause and rerun just the failed job (`gh run rerun <run-id> --failed`). That is always safe for **TestFlight External** (idempotent). For **iOS TestFlight** it is safe only if the upload never happened. A rerun after a successful upload is rejected as a duplicate build number, and the fix ships with the next tag instead.

If a draft was left behind, migrate its notes and assets onto the published release, then delete it, but only once a separate published release for the tag exists:

```sh
tag="v{version}"
if [ "$(gh release view "$tag" --json isDraft --jq '.isDraft')" = "false" ]; then
  gh api repos/mstallone/runway/releases --paginate \
    --jq '.[] | select(.draft and .tag_name=="'"$tag"'") | .id' \
    | xargs -I{} gh api -X DELETE repos/mstallone/runway/releases/{}
else
  echo "No published release for $tag yet - publish it first; do NOT delete the draft."
fi
```

## Changelog template

Only include category sections that have entries.

~~~markdown
## v{version}

### New Features
- {message} ([#{pr}]({pr_url})) by @{author}

### Bug Fixes
- {message} ([#{pr}]({pr_url})) by @{author}

### Refactor
- {message} by @{author}

### Chores
- {message} by @{author}

---

### Changelog
**Full Changelog**: [{prev_tag}...v{version}](https://github.com/mstallone/runway/compare/{prev_tag}...v{version})

- [{short_hash}](https://github.com/mstallone/runway/commit/{full_hash}) {commit message} by @{author}
~~~

`{prev_tag}` is the previous plain stable release tag. Ignore inherited suffixed beta tags.

## Rules

- 7-char short commit hashes. Tags always prefixed with `v`.
- Release tags are plain `vMAJOR.MINOR.PATCH`. Never create a suffixed prerelease tag.
- Changelogs span the previous stable release to the new one.
- Never push or tag on your own. Ask the owner first.
- Always publish notes to the GitHub Release. Never blank.
- The version is the tag. Never edit version files.
- `main` is protected: the changelog lands via PR, and the tag goes on the merged commit. Never tag before the merge.
- The appcast is append-only so older installs keep working. The workflow aborts rather than shrink it.
- Editing App ID capabilities invalidates existing provisioning profiles. Regenerate them and refresh the secrets before tagging.

Release secrets and one-time setup live in [docs/releasing.md](../../../docs/releasing.md#release-setup-one-time).
