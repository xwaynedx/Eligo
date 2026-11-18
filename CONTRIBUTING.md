# Contributing to Eligo

Thanks for your interest in contributing. This page covers the environment, the workflow, and the conventions.

## Environment

- macOS 15.0 or later.
- `swift build` and `swift test` need only a Swift 6 toolchain.
- Building the full `.app` bundle needs Xcode: `script/generate_app_icon.sh` calls `xcrun actool`, and `script/build_and_run.sh` signs the bundle with `codesign`.

## Build and test

```sh
swift build
swift test
python3 script/test-build-and-run.py
```

On Linux or macOS, run `python3 script/check-portable.py` to check Bash/Python
syntax and resource plist/JSON formats. It needs Bash and Python 3, uses only the
Python standard library, and does not execute the app or build scripts. These
static checks are configured as a separate Linux CI job; they do not
replace the macOS build and behavioral tests above.

To run the app locally:

```sh
./script/build_and_run.sh
```

The script stages and launches a local `Eligo.app` so AppKit and LaunchServices behavior can be exercised for real. By default it replaces `/Applications/Eligo.app`; set `INSTALL_DIR` to stage somewhere else. It also attempts to stop running Eligo processes before building, even with a different `INSTALL_DIR`.

The script tests use temporary repositories and command stubs for installation, process control, registration and launching. They also sign an isolated test executable with `codesign` to inspect Debug and Release entitlements; the executable is never launched. Debugging and in-place bundle usage are described in [README.md](README.md#development).

## Issues and pull requests

- Bugs and feature requests go to [GitHub Issues](https://github.com/xwaynedx/Eligo/issues). For bugs, use the bug report template and include the Support Info it asks for.
- Pull requests are welcome. Keep them focused; GitHub Actions is configured to run the Linux static checks alongside `swift build`, `swift test`, `python3 script/test-build-and-run.py`, and `bash script/test-routing-recovery.sh` on both macOS 15 and macOS 26.
- Security issues are not public issues — see [SECURITY.md](SECURITY.md).

## Conventions

- Commit messages are English [conventional commits](https://www.conventionalcommits.com/).
- Terminology follows [CONTEXT.md](CONTEXT.md), the canonical glossary for product, code, tests, and documentation. Prefer its terms (Browser Chooser, Open Destination, Domain Rule, …) over inventing synonyms.

## Releases

Releases and notarization are maintainer-only: the signing certificate and notarization credentials never leave the maintainer's machine, and external PRs do not involve `script/release.sh`.
