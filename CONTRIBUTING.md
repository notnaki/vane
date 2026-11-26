# Contributing to Vane

Thanks for helping. Bug reports, documentation fixes, accessibility improvements,
and focused code changes are all welcome.

## Before you start

- Check the [issues](https://github.com/notnaki/vane/issues) and
  [pull requests](https://github.com/notnaki/vane/pulls) for related work.
- For a big feature or an architectural change, open a feature request first so
  we can agree on the problem and scope.
- Report security issues privately under the [security policy](SECURITY.md).
  Keep passwords, tokens, and personal browsing data out of issues, logs, and
  screenshots.

Docs and small bug fixes are good first changes. The
[project structure](docs/DEVELOPMENT.md#project-structure) helps you find your way.

## Build

You need macOS 26 or later and Xcode 26 or later. There are no package
dependencies to install.

```sh
git clone https://github.com/notnaki/vane.git   # or your fork
cd vane
git switch -c my-change
./make-app.sh debug
open Vane.app
```

The build replaces `Vane.app` in the checkout. Use a separate worktree if you need
to keep another build. [Development](docs/DEVELOPMENT.md#setup-and-local-builds)
covers release builds, the CLI, and signing.

## Make the change

- Match the surrounding Swift style. Leave unrelated formatting and refactors out.
- Add or update tests when behavior changes, reusing existing fixtures.
- Keep animations brief, and respect Reduce Motion and Battery Saver.
- Update the guide in `docs/` when a control, behavior, or setup step changes.

## Test it

Run the checks that cover your change. You don't need the full suite; CI runs it
before merging.

| Change | Check |
| --- | --- |
| Docs | Links, any commands you mention, and `git diff --check`. |
| Browser or UI | Build, run the related native tests, and try the flow yourself. |
| Packaging, updates, integrations | The matching checks in [Development](docs/DEVELOPMENT.md#testing) and [Releasing](docs/RELEASING.md). |
| Website | The [website checks](docs/DEVELOPMENT.md#website-rendering-checks). |

Checks that need no Keychain or window server:

```sh
swift build -c debug
./.build/debug/vane selfcheck --pure
```

Focused native tests (swap in your test classes):

```sh
python3 scripts/run-native-tests.py --jobs 1 --filter 'PasswordAutofillTests|SavedReaderTests'
```

Native UI tests need a logged-in desktop and take focus, so don't run them in
parallel or while you're using the Mac. Quit any test copies of Vane you launch.
See [native fixture execution](docs/DEVELOPMENT.md#native-fixture-execution).

## Open a pull request

Open a PR against `main` with a short title that says what changed, and include:

- The problem and the new behavior, with the related issue if there is one.
- The checks you ran and their results, including anything you skipped.
- Before and after screenshots or a short recording for visible changes.

Every PR gets an independent review and must pass CI before it's squash-merged.
Merging doesn't publish a release. Agents and maintainers follow the full
workflow in [AGENTS.md](AGENTS.md).
