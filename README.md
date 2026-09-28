# NotchShelf

**Turn your MacBook notch into a productivity command surface.**

[![macOS CI](https://github.com/budimanr3101/notch-shelf/actions/workflows/macos-ci.yml/badge.svg)](https://github.com/budimanr3101/notch-shelf/actions/workflows/macos-ci.yml)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://github.com/budimanr3101/notch-shelf/releases)
[![Latest Release](https://img.shields.io/github/v/release/budimanr3101/notch-shelf?display_name=tag)](https://github.com/budimanr3101/notch-shelf/releases/latest)

NotchShelf is a native macOS utility that turns the physical MacBook notch into a compact workspace for moving files, opening projects, keeping DevOps references close, and running a real terminal without leaving the top of your screen.

## Download

**[Download the latest NotchShelf DMG](https://github.com/budimanr3101/notch-shelf/releases/latest)**

Official public releases are built as a macOS `.dmg`, Developer ID signed, and notarized before publishing.

### Install

1. Download `NotchShelf-<version>.dmg` from GitHub Releases.
2. Open the DMG.
3. Drag **NotchShelf** into **Applications**.
4. Launch NotchShelf from Applications.
5. Allow Finder Automation when macOS asks. NotchShelf uses it only to read the current Finder selection and destination folder for File Shelf actions.

NotchShelf runs as a menu bar utility, so it does not keep a normal Dock window open.

## Features

### File Shelf: Finder `Cmd + X` / `Cmd + V`

Stage files or folders from Finder with `Cmd + X`, move to another Finder folder, then press `Cmd + V` to move the staged items.

- `Cmd + X` stages items without moving them immediately.
- `Cmd + V` is intercepted only while NotchShelf has staged items.
- Existing destination items are never overwritten.
- The full batch is validated before mutation begins.
- Duplicate destinations and moving a folder into its own descendant are rejected.
- Cross-volume moves use a copy-then-delete fallback only for `EXDEV`.
- If the source cannot be deleted after a successful cross-volume copy, the destination copy is intentionally preserved. Duplicate data is safer than lost data.

### Developer Drop Zone

Drag a file or project toward the notch to turn it into a quick launch target.

NotchShelf can open dropped items in Finder or installed developer tools such as Terminal, iTerm2, Visual Studio Code, Cursor, Xcode, JetBrains IDEs, Warp, Zed, or a custom application you choose. The most recent dropped project is remembered for fast reopening.

### Pocketbook

Pocketbook is a searchable DevOps reference built into the notch surface.

- Quick Kubernetes and YAML references.
- `kubectl` snippets and concepts.
- Search and category filtering.
- One-click copy to the clipboard.
- Configurable global shortcut.

Default shortcut: `Option + K`.

### Native Notch Terminal

The terminal is backed by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and a real PTY, not a separate command text field.

- Login shell: `/bin/zsh -l`.
- Native Zsh prompt input and cursor.
- Tab completion from your normal Zsh configuration.
- Native shell history with arrow keys.
- `Ctrl + R` reverse history search.
- `Ctrl + C` process interruption.
- Full-screen terminal applications such as `vi`, `nvim`, and `less` can use terminal emulation instead of raw escape-sequence output.
- `TERM=xterm-256color` and true-color support.
- User Zsh startup configuration remains available.
- Long-running commands can surface a compact terminal activity indicator after the full terminal is hidden.

Default shortcut: `Shift + Command + N`.

### One Primary Notch Surface

Terminal, Pocketbook, and other primary notch experiences are coordinated so they do not stack on top of one another. Only one large primary notch surface should be visible at a time.

Transient File Shelf and Drop Zone feedback remain separate from that rule.

### Physical Notch UI

NotchShelf is designed around the physical MacBook notch rather than drawing a generic floating rounded popup. The interface expands from the hardware silhouette and preserves the connection between software and the real notch.

The current UI is therefore best experienced on a MacBook with a physical display notch.

## Shortcuts

| Action | Default |
| --- | --- |
| Stage Finder selection | `Command + X` |
| Move staged Finder items | `Command + V` |
| Open Pocketbook | `Option + K` |
| Open Notch Terminal | `Shift + Command + N` |

Pocketbook and Terminal shortcuts are configurable. Unsafe modifier-only combinations are rejected so global shortcuts do not accidentally hijack normal typing.

Global shortcut handling uses Carbon hotkey registration and does **not** require Accessibility or Input Monitoring permission.

## Privacy

NotchShelf is designed to keep terminal activity private:

- Raw terminal commands are not written to `NSLog`.
- Interactive terminal responses, including password-style input, are not copied into NotchShelf's old custom command history path.
- File operations are local. NotchShelf does not upload staged files to a remote service.

macOS may request Finder Automation permission because NotchShelf needs to read the active Finder selection and destination folder.

## Requirements

- macOS 15 or newer.
- A MacBook with a physical notch is recommended for the intended UI.
- Xcode 16+ only if you want to build from source.

## Build From Source

```bash
git clone https://github.com/budimanr3101/notch-shelf.git
cd notch-shelf
open NotchShelf.xcodeproj
```

Select your development team under **Signing & Capabilities**, choose the **NotchShelf** scheme, and run on **My Mac**.

Bundle identifier: `com.budiman.notchshelf`

SwiftTerm is pinned through Swift Package Manager for the native terminal surface.

## Release Process

Maintainer release instructions, signing secrets, notarization, DMG generation, and GitHub Release publishing are documented in [`docs/RELEASING.md`](docs/RELEASING.md).

The release workflow can create an unsigned DMG artifact for internal testing, but it refuses to publish a public GitHub Release unless Developer ID signing and Apple notarization both succeed.

## Credits

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) provides the terminal emulation layer.
- The physical-notch geometry approach is adapted from [jonnyoo/glance](https://github.com/jonnyoo/glance), which is licensed under the MIT License.

## Status

NotchShelf is under active development. CI passing means the project compiles successfully on GitHub's macOS runner; interactive terminal behavior, notch placement, drag behavior, and other UI details still need real-Mac runtime testing before each public release.
