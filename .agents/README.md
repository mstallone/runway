# Agent Skills

Skills that agents (Claude Code, Codex, Cursor) can load from this repo. `.claude` is a symlink to `.agents` so Claude Code finds them.

## Runway skills

- `release-swift/`: cut a stable release (version, changelog, tag, publish notes, verify).
- `pricing-update/`: sync `pricing_supplement.json` with Cursor's published model pricing and open a PR.

## macOS development skills

The `macos-*` skills are a local copy of OpenAI's Codex plugin [`openai/plugins/build-macos-apps`](https://github.com/openai/plugins/tree/main/plugins/build-macos-apps) (MIT). They cover building, running, and debugging macOS apps with shell-first Xcode and Swift workflows, SwiftUI and AppKit patterns, Liquid Glass, telemetry, test triage, signing, and notarization.

- `macos-appkit-interop/`
- `macos-build-run-debug/`
- `macos-liquid-glass/`
- `macos-packaging-notarization/`
- `macos-signing-entitlements/`
- `macos-swiftpm/`
- `macos-swiftui-patterns/`
- `macos-telemetry/`
- `macos-test-triage/`
- `macos-view-refactor/`
- `macos-window-management/`

Three of the plugin's slash commands are kept as explicit-invoke skills (`disable-model-invocation: true`):

- `build-and-run-macos-app/`
- `fix-codesign-error/`
- `test-macos-app/`

The plugin's manifest, Codex agent metadata, assets, and environment wiring were not carried over. `script/build_and_run.sh` is the build and run entrypoint the skills refer to.
