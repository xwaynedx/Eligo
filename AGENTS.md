# AGENTS.md

Working conventions for AI coding agents in this repository. The human-facing contribution guide is [CONTRIBUTING.md](CONTRIBUTING.md).

## Commands

- Build: `swift build`
- Test: `swift test`
- Run the app locally: `./script/build_and_run.sh` (stages and launches a local `Eligo.app`; needs Xcode)

## Conventions

- [CONTEXT.md](CONTEXT.md) is the canonical terminology baseline (Browser Chooser, Open Destination, Private Destination, Domain Rule, Routing Scope, Bypass Destination, Link Source, …). Match it in code, comments, tests, and docs; do not invent synonyms.
- Issues are tracked on [GitHub](https://github.com/xwaynedx/Eligo/issues). There is no in-repo tracker; do not add one.
- Contributions are licensed under the [Sustainable Use License, Version 1.0](LICENSE).
