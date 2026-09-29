# Releasing SuperNotch

SuperNotch supports two macOS distribution modes:

1. **Unsigned community release** — free, no Apple Developer Program required. The DMG can be published to GitHub Releases, but macOS may block the first launch until the user explicitly allows the app in System Settings → Privacy & Security.
2. **Developer ID signed and Apple-notarized release** — preferred when Apple Developer credentials are available. The same workflow automatically uses signing and notarization when the required GitHub secrets exist.

Public releases use the stable asset name `SuperNotch.dmg`. This keeps the README download URL stable across versions:

```text
https://github.com/budimanr3101/notch-shelf/releases/latest/download/SuperNotch.dmg
```

The GitHub Release tag still carries the version, for example `v0.2.0`.

## App icon

The official SN monogram icon is compiled natively from `SuperNotch/Assets.xcassets/AppIcon.appiconset`. The Xcode target uses `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, so local Debug builds and packaged Release builds use the same asset catalog. CI verifies the compiled `Assets.car` and bundle icon metadata before a DMG is accepted.

## Free unsigned release

No Apple credentials are required.

The workflow will:

1. Build SuperNotch in Release configuration, including the native AppIcon asset catalog.
2. Verify the compiled app icon metadata.
3. Create `SuperNotch.dmg` with an Applications shortcut.
4. Verify the DMG with `hdiutil verify`.
5. Generate `SuperNotch.dmg.sha256`.
6. Upload the DMG as a GitHub Actions artifact.
7. Publish a GitHub Release with an explicit **Unsigned Beta** warning and Gatekeeper instructions.

Users may need to try opening SuperNotch once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm **Open**.

## Optional signed and notarized release

If you later join the Apple Developer Program, configure these repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded `.p12` containing the Developer ID Application certificate and private key. |
| `MACOS_CERTIFICATE_PWD` | Password used when exporting the `.p12`. |
| `MACOS_KEYCHAIN_PWD` | Temporary password used for the CI signing keychain. |
| `APPLE_ID` | Apple ID used for notarization. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool`. |

When all required credentials are available, the workflow automatically:

1. Imports the Developer ID certificate into a temporary keychain.
2. Signs embedded code and `SuperNotch.app`.
3. Applies the Apple Events entitlement required for Finder automation.
4. Submits the DMG to Apple notarization.
5. Staples and validates the notarization ticket.
6. Publishes the release without the unsigned-build warning.

## Release trigger

The release version lives in `RELEASE_VERSION`.

To publish a release from `main`, update `RELEASE_VERSION` to the intended version and update `RELEASE_TRIGGER` with a new value. A release-trigger push builds and publishes that version.

The workflow also supports manual runs from **Actions → macOS Release**.

## Runtime testing

CI proves that the project builds, the app icon is compiled into the bundle, and the DMG can be packaged. It does not prove the notch UI or terminal works correctly on real hardware.

Before promoting a build broadly, test at minimum:

- SuperNotch shows the SN monogram icon in Xcode/local builds, Finder, and the mounted DMG.
- DMG opens normally.
- Dragging SuperNotch into Applications works.
- The Gatekeeper flow matches the documented unsigned-install instructions.
- Finder Automation permission can be granted.
- File Shelf `Cmd + X` / `Cmd + V` works.
- Drop Zone works.
- Pocketbook opens and copies content.
- Native terminal input, Tab completion, history, `Ctrl + R`, `Ctrl + C`, `vi`/`nvim`/`less`, and shell startup files behave correctly.
- The mini terminal activity does not appear while the full terminal remains visible.
- Only one primary notch surface is visible at a time.

## Local checksum verification

After downloading a release:

```bash
shasum -a 256 SuperNotch.dmg
cat SuperNotch.dmg.sha256
```

The hashes should match.
