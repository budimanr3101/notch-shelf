# SuperNotch App Icon

SuperNotch uses the **SN monogram** as its native macOS application icon.

The source artwork lives at `SuperNotch/Branding/AppIcon.png`. Xcode-native icon assets live in `SuperNotch/Assets.xcassets/AppIcon.appiconset` and include the standard macOS icon sizes from 16×16 through 1024×1024 Retina output.

`SuperNotch.xcodeproj` sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, so Debug builds, Release builds, Finder, Dock, and packaged DMGs all use the same icon through the normal Xcode asset-catalog pipeline. The release workflow verifies the compiled icon metadata before creating the DMG.
