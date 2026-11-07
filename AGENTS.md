# LockScreenRestore workspace notes

## Build

This workspace uses Apelin's external build script (`build.sh`), not Theos. The script currently supports the RootHide target only and builds one `iphoneos-arm64e` package containing `Tweak.m`, `LSRWallpaperPane.m`, the Settings preference bundle, and the existing filter. Build it with Apelin's `apelin_project_build` for `roothide` (debug or release); the script locates the current RootHide development support from the build-provided project path, compiles and signs the Mach-O files, then writes the single package to `APELIN_PACKAGE_DIR`.

Install only the package artifact returned by `apelin_project_build` through `apelin_package_install`. If installation reports an existing package from another source, do not remove or replace it here; the user must remove it through their package manager before retrying.

## Verification

A successful build verifies compilation, linking, signing and packaging only. After installation, use `apelin_package_confirm_loaded` for SpringBoard with `respring: true`, then verify the Lock Screen behavior. Do not report the lock icon's size or alignment as verified until it has been observed on-device; Ask Before Using the Screen is enabled, so request consent before reading or interacting with the UI, and request separate explicit consent for a screenshot.
