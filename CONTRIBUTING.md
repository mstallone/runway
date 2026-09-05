# Contributing to Runway

Runway uses an issue-first workflow. External pull requests must link an issue a maintainer has approved with the `approved` label. PRs without one are closed without review. Read this page before opening a PR.

## Scope

Runway tracks AI coding subscription usage. That is the whole feature set. It is opinionated about clean design, speed, and a simple UX. Changes that expand the scope, add complexity, or hurt the UX are closed.

If you are unsure whether an idea fits, open an issue first.

## Rules

- **Get an issue approved first.** External PRs must link an open issue labeled `approved`.
- **Keep PRs under 1,000 changed lines.** Split larger work.
- **One concern per PR.** Do not bundle unrelated changes.
- **Write your own commit messages.** No AI-generated commit messages.
- **Test your change and say how in the PR.**
- **Keep it simple.** Do not over-engineer.
- **Match the existing design language.** [AGENTS.md](AGENTS.md) documents the conventions.

Closures are not personal and are reversible. Get the issue approved or fix the problem, then reopen or open a focused replacement. Maintainers and collaborators can open PRs directly.

By submitting a pull request you agree your contribution is licensed under the [MIT License](LICENSE).

## Workflow

1. Open an issue and wait for the `approved` label.
2. Fork the repo and create a branch (`feat/my-change`, `fix/some-bug`).
3. Make only the approved change.
4. Run `swift build` and `swift test`.
5. Open a PR against `main` with `Fixes #<issue>` and the PR description structure from [AGENTS.md](AGENTS.md).

### Adding a provider

A provider is a small Swift module under `Sources/Runway/Providers/<Name>/` that conforms to `ProviderRuntime`: an auth store reads credentials already on the machine, a usage client calls the provider API, and a mapper turns the response into metric lines. See [docs/adding-a-provider.md](docs/adding-a-provider.md) and [docs/architecture.md](docs/architecture.md).

1. Open an issue and get it approved. Say why the provider fits and how its usage data is accessible.
2. Create `Sources/Runway/Providers/<Name>/` and implement `ProviderRuntime`.
3. Register the provider in `AppContainer`.
4. Add tests under `Tests/RunwayTests/`.
5. Add a page in `docs/providers/` (metrics, credential sources, endpoints, troubleshooting).
6. Test it with `./script/build_and_run.sh`.
7. Open a PR that says how you verified it.

You can also [request a provider](https://github.com/mstallone/runway/issues/new?template=new_provider.yml) without building it.

### Fixing a bug

Reference the approved issue, describe the root cause and fix, and add a regression test where it fits.

### Requesting a feature

[Open an issue](https://github.com/mstallone/runway/issues/new?template=feature_request.yml) and wait for the `approved` label before writing code.

## What gets accepted

- Bug fixes with clear descriptions
- New providers that follow the existing provider structure
- Documentation improvements
- Performance improvements with benchmarks
- Accessibility improvements

## What gets rejected

- External PRs without an approved issue
- PRs over 1,000 lines, or that bundle unrelated changes
- Features outside usage tracking
- Changes that hurt speed, simplicity, or the existing UX
- PRs without testing evidence
- Code with no clear purpose
- Cosmetic-only changes without prior discussion

## Code standards

- Swift 6 with strict concurrency, built with SwiftPM (no Xcode project)
- Follow existing patterns. [AGENTS.md](AGENTS.md) is the engineering contract.
- User-visible behavior changes must update the matching `docs/` page in the same PR.
- UI copy is plain language and sentence case.
- No new dependencies without a reason.

## Maintainers

- [@mstallone](https://github.com/mstallone) (owner)

All PRs need maintainer approval to merge. Only the owner can create release tags (`v*`).

## Questions

Open a [bug report](https://github.com/mstallone/runway/issues/new?template=bug_report.yml) or [feature request](https://github.com/mstallone/runway/issues/new?template=feature_request.yml).
