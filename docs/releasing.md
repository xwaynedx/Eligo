# Eligo release process

The first public release is source-only, with version `0.2.0`. Users build the app by following the [README](../README.md#install). No prebuilt download is available yet.

## Source releases

1. Keep `VERSION` and the planned versions in [CHANGELOG.md](../CHANGELOG.md) and [CHANGELOG.zh-CN.md](../CHANGELOG.zh-CN.md) consistent. Keep the release contents aligned across both languages. While preparing a release, keep the English notes under `Unreleased` and the Chinese notes under `尚未发布`.
2. Push the release candidate to `main` and confirm that `linux-checks`, `build-and-test (macos-15)`, and `build-and-test (macos-26)` all pass for that commit.
3. On the release date, change both changelog headings to `<version> — YYYY-MM-DD` using the actual publication date. For `0.2.0`, also replace the planning paragraph below each heading. Use “Eligo’s first public release is distributed as source code.” in English and “Eligo 首个公开版本以源码形式发布。” in Chinese. Commit both changelogs together, push the dated commit to GitHub’s `main` branch, and wait for all three CI checks to pass on that commit.
4. Create a `v<version>` tag, such as `v0.2.0`, on the exact commit that passed CI, then publish the tag and release notes. The first release has source archives only, with no application ZIP attached.

Do not move an already published tag. Subsequent public releases use new versions and ordinary commits.

## Application ZIP releases

Public application downloads require the update-check feature and corresponding privacy documentation first. They also require the signing, notarization and real-browser checks below; an ad-hoc build is for local development.

The release script builds `arm64` and `x86_64`, assembles the signed bundle, creates a ZIP, and writes its SHA-256 checksum. The first application ZIP will use a version after `0.2.0`.

## One-time setup

1. Replace the default `io.github.xwaynedx.eligo` if you own a different reverse-DNS namespace. Keep the chosen identifier stable across releases.
2. Install a `Developer ID Application` certificate in the login keychain.
3. Store App Store Connect credentials for notarization:

   ```sh
   xcrun notarytool store-credentials Eligo-notary
   ```

## Local release validation

This verifies the Universal Release build, bundle metadata, compiled App Icon asset catalog, hardened runtime, resources, and archive without claiming it is publicly trusted:

```sh
BUILD_NUMBER=1 script/release.sh --adhoc
```

## Signed and notarized release

```sh
BUILD_NUMBER=1 \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="Eligo-notary" \
script/release.sh --notarize
```

Outputs are written to `dist/release/`:

- `Eligo.app`
- `Eligo-<version>-<build>.zip`
- `Eligo-<version>-<build>.zip.sha256`

The public release gate is complete only after `notarytool`, stapling, and Gatekeeper assessment all pass. Increment `VERSION` for a user-visible release and use a unique, increasing `BUILD_NUMBER` for every submitted build.

To publish Apple-Silicon-only intentionally, set `ARCHS=arm64` and disclose that requirement in the release notes.

## Product release checklist

- Confirm the version in `VERSION` and the build number for the submission.
- Confirm the final Bundle ID and Developer ID Application identity.
- Review `README.md`, `README.zh-CN.md`, `CHANGELOG.md`, `CHANGELOG.zh-CN.md`, `docs/privacy.md`, and `docs/support.md`. Confirm that the language-switch links and both chooser screenshots are included in the public source tree.
- Open About Eligo and confirm the displayed version, privacy statement, and Support Guide.
- Confirm Launch at Login is optional and documented in Settings.
- Run the real-browser smoke matrix before publishing the ZIP.
- Publish the ZIP checksum with the release notes.
