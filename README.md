# NotchShelf

**Cut. Carry. Paste.**

NotchShelf is a small macOS utility that turns the MacBook notch into a transient file shelf.

## MVP

1. Select one or more files/folders in Finder.
2. Press `Cmd + X` to stage them in NotchShelf.
3. Navigate to the destination folder in Finder.
4. Press `Cmd + V` to move the staged items there.

The original files are not moved when `Cmd + X` is pressed. They are only moved after `Cmd + V`.

## Notch UI

- The overlay is anchored to the physical MacBook notch.
- The closed software silhouette matches the measured hardware notch and expands downward/outward from it.
- There is intentionally no floating-pill fallback on displays without a physical notch.
- Notch geometry and silhouette behavior are adapted from the approach used by [jonnyoo/glance](https://github.com/jonnyoo/glance), licensed under MIT.

## Safety behavior

- Existing destination names are never overwritten in the MVP.
- Same-folder moves are rejected.
- Cross-volume moves copy first and delete the source only after the copy succeeds.
- `Cmd + V` is intercepted only while NotchShelf actually has staged items. Otherwise Finder receives the shortcut normally.

## Requirements

- macOS 15+
- Xcode 16+
- Finder Automation permission when macOS asks for it

Global `Cmd + X` / `Cmd + V` handling uses Carbon hotkey registration and does not require Accessibility or Input Monitoring permission.

## Build

Open `NotchShelf.xcodeproj`, select your Personal Team under **Signing & Capabilities**, then run on **My Mac**.

Bundle identifier: `com.budiman.notchshelf`
