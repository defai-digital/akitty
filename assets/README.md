# AkiTTY brand assets

`logo.png` is the user-supplied full logo. `icon-source.png` is an icon-only
adaptation retaining the navy cat, orange details and terminal-symbol eyes.
The wordmark is omitted from the app icon for readability at Dock/Finder sizes.

`scripts/build-icons.swift` generates 16, 32, 128, 256 and 512 point images at
1x/2x, including a 1024-pixel master, and `iconutil` packages the ICNS used by
macOS 14 and later. Source transparency and consistent optical margins are
preserved. No account or source-machine metadata is written into generated PNGs.

This is a conventional flat ICNS asset, not a claim of a layered Liquid Glass
Icon Composer asset. Future layered variants can reuse the cat as foreground.
Apple guidance: https://developer.apple.com/design/human-interface-guidelines/app-icons
