<h1 align="center">SuperNotch</h1>

<h3 align="center">Turn your MacBook notch into a native productivity command surface.</h3>

<p align="center">
  File Shelf · Developer Drop Zone · Pocketbook · Native Terminal
</p>

<p align="center">
  <a href="https://github.com/budimanr3101/notch-shelf/actions/workflows/macos-ci.yml"><img src="https://github.com/budimanr3101/notch-shelf/actions/workflows/macos-ci.yml/badge.svg" alt="macOS CI"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black.svg?logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-black.svg?logo=swift" alt="Swift / SwiftUI">
  <a href="https://github.com/budimanr3101/notch-shelf/releases/latest"><img src="https://img.shields.io/github/v/release/budimanr3101/notch-shelf?display_name=tag&label=release&color=black" alt="Latest Release"></a>
</p>

<p align="center">
  <a href="https://github.com/budimanr3101/notch-shelf/releases/latest/download/SuperNotch.dmg"><img src="https://img.shields.io/badge/Download_for_macOS-SuperNotch.dmg-black?style=for-the-badge&logo=apple" alt="Download SuperNotch for macOS"></a>
</p>

**SuperNotch** is a native macOS utility that turns the physical MacBook notch into a compact workspace. Stage and move Finder files, launch developer projects, keep Kubernetes and DevOps references nearby, and open a real Zsh terminal directly from the top of your screen.

Unlike a detached floating pill, SuperNotch is designed around the real display notch. Its primary surfaces expand from the hardware area and collapse back into it when you are done.

---

## Download & Installation

**Requirements**

- macOS 15 or later
- A MacBook with a physical display notch is recommended

1. Download [`SuperNotch.dmg`](https://github.com/budimanr3101/notch-shelf/releases/latest/download/SuperNotch.dmg).
2. Open the DMG.
3. Drag **SuperNotch** into **Applications**.
4. Try to launch SuperNotch from Applications.
5. If macOS blocks the first launch, open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** for SuperNotch, then confirm **Open**.
6. Allow Finder Automation when macOS asks for it.

SuperNotch runs as a menu bar utility, so it does not keep a normal Dock window open.

> [!WARNING]
> Current free releases are **unsigned and not Apple-notarized**. macOS may warn that the developer cannot be verified or that Apple cannot check the app for malicious software. Only download SuperNotch from this official GitHub repository and verify the included SHA-256 checksum if you want to confirm the downloaded DMG matches the published artifact.

## What SuperNotch can do

| Feature | Description |
| --- | --- |
| **File Shelf** | Use Finder `Command + X` to stage files and `Command + V` to move them into another Finder folder. |
| **Developer Drop Zone** | Drag a file or project toward the notch and open it quickly in Finder, Terminal, iTerm2, VS Code, Cursor, Xcode, JetBrains IDEs, Warp, Zed, or a custom app. |
| **Pocketbook** | Searchable Kubernetes, YAML, `kubectl`, and DevOps references with fast clipboard copy. |
| **Native Terminal** | A real PTY powered by SwiftTerm with native Zsh input, Tab completion, history, `Ctrl + R`, `Ctrl + C`, and interactive terminal apps. |
| **Background Terminal Activity** | Long-running commands can surface a compact activity indicator after the full terminal is hidden. |
| **Single Primary Surface** | Terminal, Pocketbook, and other large notch experiences are coordinated so they do not stack on top of each other. |
| **Physical Notch UI** | The interface expands from the real MacBook notch geometry instead of imitating it with a detached floating window. |

## File Shelf

Select one or more files or folders in Finder, press `Command + X`, navigate to another folder, then press `Command + V`.

The original files are **not** moved when `Command + X` is pressed. They are moved only after `Command + V`.

SuperNotch applies a conservative file-move policy:

- Existing destination items are never overwritten.
- The entire batch is validated before mutation starts.
- Duplicate destinations are rejected.
- Moving a folder into its own descendant is rejected.
- Cross-volume moves fall back to copy-then-delete only for `EXDEV`.
- If the source cannot be deleted after a successful cross-volume copy, the destination copy is preserved. Duplicate data is safer than lost data.

## Developer Drop Zone

Drop a file or project near the notch and SuperNotch can route it to the developer tool you use most.

Supported built-in targets include:

- Finder
- Terminal
- iTerm2
- Visual Studio Code
- Cursor
- Xcode
- IntelliJ IDEA
- WebStorm
- PyCharm
- GoLand
- Rider
- DataGrip
- Warp
- Zed
- Custom macOS application

The most recent project is remembered so it can be reopened quickly from the menu bar.

## Pocketbook

Pocketbook keeps common DevOps references one shortcut away.

- Kubernetes and YAML references
- `kubectl` snippets
- Search and category filtering
- One-click clipboard copy
- Configurable global shortcut

Default shortcut: `Option + K`.

## Native Terminal

SuperNotch Terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) with a real PTY and `/bin/zsh -l`.

That means terminal input goes directly to the shell instead of through a separate command field.

- Native shell prompt and cursor
- Zsh Tab completion
- Arrow-key command history
- `Ctrl + R` reverse history search
- `Ctrl + C` process interruption
- `vi`, `nvim`, `less`, and other terminal applications can use terminal emulation
- `TERM=xterm-256color`
- True-color terminal support
- Existing Zsh startup configuration remains available

Default shortcut: `Shift + Command + N`.

## Shortcuts

| Action | Default |
| --- | --- |
| Stage Finder selection | `Command + X` |
| Move staged Finder items | `Command + V` |
| Open Pocketbook | `Option + K` |
| Open SuperNotch Terminal | `Shift + Command + N` |

Pocketbook and Terminal shortcuts are configurable. Unsafe Shift-only global shortcuts are rejected so SuperNotch does not accidentally hijack normal typing.

Global hotkeys use Carbon registration and do **not** require Accessibility or Input Monitoring permission.

## Privacy

SuperNotch is designed to keep file and terminal activity local.

- Raw terminal commands are not written to `NSLog`.
- Interactive terminal responses are not copied into the legacy custom-command history path.
- Staged files are moved locally and are not uploaded to a remote service.
- Finder Automation is used only to read the current Finder selection and destination folder for File Shelf actions.

## Building from source

### Prerequisites

- macOS 15+
- Xcode 16+

```bash
git clone https://github.com/budimanr3101/notch-shelf.git
cd notch-shelf
open SuperNotch.xcodeproj
```

Select your development team under **Signing & Capabilities**, choose the **SuperNotch** scheme, and run on **My Mac**.

Bundle identifier: `com.budiman.supernotch`

SwiftTerm is pinned through Swift Package Manager for the native terminal surface.

## Contributing

Issues and pull requests are welcome. For UI changes, please preserve the physical-notch geometry and avoid replacing the hardware-connected notch surface with a detached floating pill.

## Release process

Maintainer instructions for unsigned community releases and optional Developer ID signing / Apple notarization are documented in [`docs/RELEASING.md`](docs/RELEASING.md).

CI passing means the project compiles successfully on GitHub's macOS runner. Interactive terminal behavior, notch placement, drag behavior, and other UI details still require real-Mac runtime testing before a public release.

## Credits

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) provides the native terminal emulation layer.
- The physical-notch geometry approach is adapted from [jonnyoo/glance](https://github.com/jonnyoo/glance), licensed under MIT.

---

<p align="center"><strong>SuperNotch</strong> · Your notch. Now useful.</p>
