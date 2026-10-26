# Contributing to Vane

Thanks for helping improve Vane. Bug reports, documentation fixes, accessibility
improvements, and focused code changes are welcome.

## Before you start

- Search the [existing issues](https://github.com/notnaki/vane/issues) and
  [pull requests](https://github.com/notnaki/vane/pulls) for related work.
- For a larger feature or architectural change, open a feature request first so
  maintainers can discuss the problem and scope with you.
- Report vulnerabilities privately using the [security policy](SECURITY.md).
  Keep passwords, tokens, personal browsing data, and private documents out of
  public reports, logs, and screenshots.

Documentation and small bug fixes are good starting points. The
[documentation index](docs/README.md) and the development guide's
[project structure](docs/DEVELOPMENT.md#project-structure) help you find the
relevant files.

## Set up a local build

Use macOS 26 or later and Xcode 26 or later with its included Swift toolchain.
No package dependency installation is required.

Fork the repository if you do not have write access, then clone your fork.
Otherwise, clone the main repository:

```sh
git clone https://github.com/notnaki/vane.git
cd vane
git switch -c codex/describe-your-change
xcodebuild -version
swift --version
./make-app.sh debug
open Vane.app
```

The build replaces the generated `Vane.app` in this checkout and signs it ad hoc
for local development. Use a separate checkout or worktree if you need to keep
another build intact. See [development setup](docs/DEVELOPMENT.md#setup-and-local-builds)
for release builds, CLI commands, and signing details.

## Make a focused change

- Match the surrounding Swift style and existing feature boundaries. Keep
  unrelated formatting and refactors out of the change.
- Add or update regression coverage when behavior changes; use existing test
  fixtures where possible.
- Keep UI transitions brief and consistent. Respect Reduce Motion and Battery
  Saver, and animate shape or orientation changes continuously.
- Update the relevant user or developer guide when controls, behavior, or setup
  change. Describe known limits and skipped validation accurately.

## Validate the affected behavior

Choose checks that exercise your change. You do not need to run the full local
suite for every PR; required CI still applies before merging.

| Change | Local validation |
| --- | --- |
| Markdown documentation | Check links, referenced commands, and `git diff --check`. |
| Browser or UI behavior | Build, run relevant native regression tests, and manually exercise the affected flow on a logged-in macOS desktop. |
| Packaging, updater, or integrations | Use the relevant checks in [Development](docs/DEVELOPMENT.md#testing) and [Releasing](docs/RELEASING.md). |
| Website | Use the [website rendering checks](docs/DEVELOPMENT.md#website-rendering-checks). |

For a debug executable build and checks that need neither Keychain nor a window
server:

```sh
swift build -c debug
./.build/debug/vane selfcheck --pure
```

For focused native tests, replace the example filter with the affected test
classes:

```sh
python3 scripts/run-native-tests.py --jobs 1 --filter 'PasswordAutofillTests|SavedReaderTests'
```

Native UI fixtures need a logged-in desktop. Do not use `--parallel` on the same
desktop: fixtures share focus and application state. The wrapper verifies cleanup
of its owned WebKit stores after the test host exits. See
[native fixture execution](docs/DEVELOPMENT.md#native-fixture-execution) for full
runs, CI sharding, and cleanup diagnostics.

Track the bundle path, PID, and process start time of test apps you launch. Quit
and verify exit of those instances when finished; leave your regular Vane app and
other tasks' instances running. Follow [AGENTS.md](AGENTS.md) for the complete
review, test-app cleanup, and worktree cleanup workflow.

## Open a pull request

Push your branch to your fork or the repository and open a PR targeting `main`.
Use a short title that describes the result, then include:

- The problem, resulting behavior, and related issue if one exists.
- Checks you ran and their results, including any skips or environment limits.
- Before/after screenshots or a short recording for visible UI changes.

For native validation, include macOS and Xcode/SDK versions and relevant signing
or account requirements. Documentation-only PRs can state that app tests were
not run and list the documentation checks instead.

Maintainers obtain an independent review of the current PR diff, address
actionable findings, and wait for required CI and approvals before squash-merging.
Merging does not publish a release. Contribution workflow details live in
[AGENTS.md](AGENTS.md); release procedures live in [Releasing](docs/RELEASING.md).
