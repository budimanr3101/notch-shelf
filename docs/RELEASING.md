# Releasing NotchShelf

NotchShelf public releases are distributed as a Developer ID signed and Apple-notarized DMG through GitHub Releases.

The release workflow also supports an unsigned DMG artifact for internal testing, but it deliberately refuses to publish that artifact as a public release.

Public releases use the stable asset name `NotchShelf.dmg`. This keeps the README download URL stable across versions:

```text
https://github.com/budimanr3101/notch-shelf/releases/latest/download/NotchShelf.dmg
```

The GitHub Release tag and title still carry the actual version, for example `v0.1.0` and `NotchShelf 0.1.0`.

## Prerequisites

- An active Apple Developer Program membership.
- A **Developer ID Application** certificate for the Apple Developer team used to distribute NotchShelf.
- An Apple ID that can submit notarization requests for that team.
- An app-specific password for that Apple ID.

## GitHub Actions secrets

Configure these repository secrets under **Settings → Secrets and variables → Actions**.

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded `.p12` containing the Developer ID Application certificate and private key. |
| `MACOS_CERTIFICATE_PWD` | Password used when exporting the `.p12`. |
| `MACOS_KEYCHAIN_PWD` | Temporary password used for the CI signing keychain. Use a strong random value. |
| `APPLE_ID` | Apple ID used for notarization. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool`. |

### Export and encode the certificate

Export the **Developer ID Application** certificate and its private key from Keychain Access as a password-protected `.p12` file.

On macOS, encode it for the `MACOS_CERTIFICATE` secret:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the clipboard value into the GitHub secret. Do not commit the `.p12` file, private key, Apple ID password, or app-specific password to the repository.

## What the workflow does

`.github/workflows/release.yml` performs the following steps:

1. Builds NotchShelf in Release configuration.
2. Enables the Hardened Runtime for the release build.
3. Imports the Developer ID certificate into a temporary CI keychain when signing secrets are available.
4. Signs embedded frameworks and `NotchShelf.app`.
5. Applies the Apple Events entitlement required for Finder automation.
6. Creates `NotchShelf.dmg` with an Applications shortcut.
7. Submits the DMG to Apple with `notarytool`.
8. Staples and validates the notarization ticket.
9. Generates `NotchShelf.dmg.sha256`.
10. Uploads a versioned workflow artifact such as `NotchShelf-0.1.0-dmg` for testing.
11. Publishes `NotchShelf.dmg` and its checksum to GitHub Releases only when signing and notarization succeeded.

## Recommended release sequence

### 1. Prepare the release on a branch

Update the version, release notes, README, or other release metadata as needed and let macOS CI pass.

### 2. Merge the release preparation to `main`

Do not publish directly from a feature branch. Manual public publishing is restricted to `main`.

### 3. Build a non-public DMG first

Open **Actions → macOS Release → Run workflow** on `main`.

Use:

- `version`: for example `0.1.0`
- `publish`: **false**

The workflow will build, sign, notarize, and upload the DMG as a workflow artifact without creating a public GitHub Release.

Download that artifact and runtime-test it on a real Mac. At minimum verify:

- DMG opens normally.
- Dragging NotchShelf into Applications works.
- Gatekeeper accepts the application without an unsigned-app warning.
- Finder Automation permission can be granted.
- File Shelf `Cmd + X` / `Cmd + V` works.
- Drop Zone works.
- Pocketbook opens and copies content.
- Native terminal input, Tab completion, history, `Ctrl + R`, `Ctrl + C`, `vi`/`nvim`/`less`, and shell startup files behave correctly.
- The mini terminal activity does not appear while the full terminal remains visible.
- Only one primary notch surface is visible at a time.

CI build success is not a substitute for this real-Mac runtime test.

### 4. Publish

After the DMG passes runtime testing, run **macOS Release** again on `main` with the same version and:

- `publish`: **true**

The workflow creates the `v<version>` tag and GitHub Release if they do not already exist, then uploads:

- `NotchShelf.dmg`
- `NotchShelf.dmg.sha256`

A tag push matching `v*` also triggers the release workflow and is treated as a publish request.

## Local checksum verification

After downloading a release:

```bash
shasum -a 256 NotchShelf.dmg
cat NotchShelf.dmg.sha256
```

The hashes should match.

## Troubleshooting

### `Developer ID Application identity was not found`

The imported `.p12` does not contain a usable Developer ID Application certificate and private key, or the certificate has expired.

### Notarization is rejected

Open the failed GitHub Actions run and inspect the `notarytool` output. Common causes include signing problems, an expired certificate, missing hardened-runtime requirements, or invalid bundle contents.

### Public release step refuses to run

This is intentional if signing or notarization credentials are missing. Build with `publish: false` for an internal artifact, configure the required secrets, then rerun the workflow.
