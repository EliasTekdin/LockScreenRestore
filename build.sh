#!/bin/sh
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"

[ "$APELIN_BOOTSTRAP" = roothide ] || { echo "This workspace build currently supports RootHide only." >&2; exit 2; }
[ "$APELIN_ARCHITECTURE" = iphoneos-arm64e ] || { echo "Unexpected RootHide architecture: $APELIN_ARCHITECTURE" >&2; exit 2; }

# Apelin's shared project container and its development extensions have different
# parent directories, but share the current RootHide jbroot suffix. Derive that
# suffix from the build-provided project path for this run only.
case "$APELIN_PROJECT_ROOT" in
    *"/.jbroot-"*) root_suffix=${APELIN_PROJECT_ROOT#*"/.jbroot-"}; root_id=${root_suffix%%/*} ;;
    *) echo "Could not derive RootHide jbroot id from APELIN_PROJECT_ROOT" >&2; exit 2 ;;
esac
support_root="/private/var/containers/Bundle/Application/.jbroot-$root_id"
if [ ! -f "/rootfs${support_root}/usr/share/apelin/development/wiki.qaq.apelin.dev.tweak/support/lib/roothide/libsubstrate.tbd" ]; then
    echo "Apelin RootHide support not found under the current development root." >&2
    exit 2
fi

tweak_support="$support_root/usr/share/apelin/development/wiki.qaq.apelin.dev.tweak/support"
prefs_support="$support_root/usr/share/apelin/development/wiki.qaq.apelin.dev.preferences/support"
stage="$(mktemp -d "${TMPDIR:?}lsr-stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT

arch=arm64e
mkdir -p "$stage/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$stage/Library/PreferenceBundles/LockScreenRestorePrefs.bundle/Resources"
mkdir -p "$stage/Library/PreferenceLoader/Preferences"
mkdir -p "$stage/DEBIAN"

clang -dynamiclib -arch "$arch" -fobjc-arc -fblocks -fvisibility=hidden \
    -DAPELIN_BOOTSTRAP_ROOTHIDE=1 \
    -DAPELIN_PACKAGE_ID=\"com.aronsz26.lockscreenrestore\" \
    -DAPELIN_BUILD_ID=\"$APELIN_BUILD_ID\" \
    -I"$tweak_support/include" -L"$tweak_support/lib/roothide" \
    Tweak.m LSRWallpaperPane.m DebugTools.m \
    -framework Foundation -framework UIKit -framework CoreText -framework AVFoundation \
    -framework CoreGraphics -framework CoreMedia -framework ImageIO -framework CoreMotion -framework QuartzCore \
    -lsubstrate -Wl,-rpath,@loader_path/.jbroot/usr/lib \
    -o "$stage/Library/MobileSubstrate/DynamicLibraries/LockScreenRestore.dylib"
ldid -S "$stage/Library/MobileSubstrate/DynamicLibraries/LockScreenRestore.dylib"
cp LockScreenRestore.plist "$stage/Library/MobileSubstrate/DynamicLibraries/LockScreenRestore.plist"
ln -s ../../../usr/lib/DynamicPatches/AutoPatches.dylib \
    "$stage/Library/MobileSubstrate/DynamicLibraries/LockScreenRestore.dylib.roothidepatch"

prefs_bundle="$stage/Library/PreferenceBundles/LockScreenRestorePrefs.bundle"
clang -bundle -arch "$arch" -fobjc-arc -fblocks -fvisibility=hidden \
    -I"$prefs_support/include" \
    -F"$prefs_support/stubs" -F"$SDKROOT/System/Library/PrivateFrameworks" \
    lockscreenrestoreprefs/LSRRootListController.m \
    -framework UIKit -framework Preferences -framework FrontBoardServices -framework SpringBoardServices \
    -o "$prefs_bundle/LockScreenRestorePrefs"
ldid -S "$prefs_bundle/LockScreenRestorePrefs"
cp lockscreenrestoreprefs/Resources/Info.plist "$prefs_bundle/Info.plist"
cp lockscreenrestoreprefs/Resources/Root.plist "$prefs_bundle/Resources/Root.plist"
cp lockscreenrestoreprefs/Resources/icon.png "$prefs_bundle/Resources/icon.png"
cp lockscreenrestoreprefs/entry.plist "$stage/Library/PreferenceLoader/Preferences/LockScreenRestorePrefs.plist"

sed "s/^Architecture:.*/Architecture: $APELIN_ARCHITECTURE/" control > "$stage/DEBIAN/control"

dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/LockScreenRestore.deb"
