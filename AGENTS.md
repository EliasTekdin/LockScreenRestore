# LockScreenRestore workspace notes

## Build

This workspace uses Apelin's external `build.sh` script, not Theos. It supports two separate targets:

- RootHide: `iphoneos-arm64e`, built as an arm64e slice.
- Rootless: `iphoneos-arm64`, built with arm64 and arm64e slices.

Build each target with `apelin_project_build` for `roothide` or `rootless`. The script uses Apelin's registered tweak and preferences support stubs, compiles and signs the Objective-C tweak and Settings bundle, applies the bootstrap-specific substrate link/rpath and package layout, then writes exactly one package to `APELIN_PACKAGE_DIR`. It relies on the build-provided paths and target variables; do not store a resolved RootHide path in project files.

Install only a package artifact returned by `apelin_project_build` through `apelin_package_install`. If installation reports an existing package from another source, do not remove or replace it here; the user must remove it through their package manager before retrying.

## Verification

A successful build verifies compilation, linking, signing and packaging only. After installation, use `apelin_package_confirm_loaded` for SpringBoard with `respring: true`, then verify the Lock Screen behavior. Do not report the lock icon's size, alignment or scroll movement as verified until it has been observed on-device; Ask Before Using the Screen is enabled, so request consent before reading or interacting with the UI, and request separate explicit consent for a screenshot.

Built `.deb` files remain Apelin build artifacts outside the source tree. Do not copy or commit packages into a `debs/` folder; use Apelin's distribution or package-repository publishing tools when the user asks for package delivery.
