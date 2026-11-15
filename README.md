# Fold Craft Launcher for iOS

An iOS port of [Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher), written in Swift and SwiftUI.

## Build

The project is generated with XcodeGen from `project.yml` and built by GitHub Actions (`.github/workflows/build-ios.yml`). Every push produces an unsigned IPA artifact named `FoldCraftLauncher-unsigned-ipa`. Sign it on device with KSign or ESign.

## JIT

The Java virtual machine requires JIT. Enable it with StikDebug from the Home tab or from StikDebug directly using the bundle identifier `com.nxteam.foldcraftlauncher.test`.

## License

GPL 3.0, same as the original Fold Craft Launcher.
