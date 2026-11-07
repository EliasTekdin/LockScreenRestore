#!/bin/sh
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"

case "$APELIN_BOOTSTRAP:$APELIN_ARCHITECTURE:$APELIN_PREFIX" in
    roothide:iphoneos-arm64e:"")
        archs="arm64e"
        support_kind=roothide
        case "$APELIN_PROJECT_ROOT" in
            *"/.jbroot-"*) root_suffix=${APELIN_PROJECT_ROOT#*"/.jbroot-"}; root_id=${root_suffix%%/*} ;;
            *) echo "Could not derive RootHide development root from APELIN_PROJECT_ROOT" >&2; exit 2 ;;
        esac
        support_root="/private/var/containers/Bundle/Application/.jbroot-$root_id"
        ;;
    rootless:iphoneos-arm64:/var/jb)
        archs="arm64 arm64e"
        support_kind=rootless
        # The build host's Apelin support is installed in its current development
        # root; APELIN_PREFIX describes the package target, not that host path.
        case "$APELIN_PROJECT_ROOT" in
            *"/.jbroot-"*) root_suffix=${APELIN_PROJECT_ROOT#*"/.jbroot-"}; root_id=${root_suffix%%/*} ;;
            *) echo "Could not derive the active development root from APELIN_PROJECT_ROOT" >&2; exit 2 ;;
        esac
        support_root="/private/var/containers/Bundle/Application/.jbroot-$root_id"
        ;;
    *)
        echo "Unsupported build target: $APELIN_BOOTSTRAP / $APELIN_ARCHITECTURE / $APELIN_PREFIX" >&2
        exit 2
        ;;
esac

tweak_support="$support_root/usr/share/apelin/development/wiki.qaq.apelin.dev.tweak/support"
prefs_support="$support_root/usr/share/apelin/development/wiki.qaq.apelin.dev.preferences/support"
if [ ! -f "$tweak_support/lib/$support_kind/libsubstrate.tbd" ]; then
    echo "Apelin $APELIN_BOOTSTRAP tweak support was not found in the current development root." >&2
    exit 2
fi

stage="$(mktemp -d "${TMPDIR:?}lsr-stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT
work="$stage/build"
prefix_stage="$stage${APELIN_PREFIX}"
mkdir -p "$work" \
    "$prefix_stage/Library/MobileSubstrate/DynamicLibraries" \
    "$prefix_stage/Library/PreferenceBundles/LockScreenRestorePrefs.bundle/Resources" \
    "$prefix_stage/Library/PreferenceLoader/Preferences" \
    "$stage/DEBIAN"

tweak_output="$prefix_stage/Library/MobileSubstrate/DynamicLibraries/LockScreenRestore.dylib"
prefs_output="$prefix_stage/Library/PreferenceBundles/LockScreenRestorePrefs.bundle/LockScreenRestorePrefs"

for arch in $archs; do
    clang -dynamiclib -arch "$arch" -fobjc-arc -fblocks -fvisibility=hidden \
        -DAPELIN_BOOTSTRAP_$( [ "$APELIN_BOOTSTRAP" = roothide ] && echo ROOTHIDE || echo ROOTLESS )=1 \
        -DAPELIN_PACKAGE_ID=\"com.aronsz26.lockscreenrestore\" \
        -DAPELIN_BUILD_ID=\"$APELIN_BUILD_ID\" \
        -I"$tweak_support/include" -L"$tweak_support/lib/$support_kind" \
        Tweak.m LSRWallpaperPane.m DebugTools.m \
        -framework Foundation -framework UIKit -framework CoreText -framework AVFoundation \
        -framework CoreGraphics -framework CoreMedia -framework ImageIO -framework CoreMotion -framework QuartzCore \
        -lsubstrate \
        $( [ "$APELIN_BOOTSTRAP" = roothide ] && printf '%s' '-Wl,-rpath,@loader_path/.jbroot/usr/lib' || printf '%s' '-Wl,-rpath,/var/jb/Library/Frameworks' ) \
        -o "$work/LockScreenRestore-$arch.dylib"

    clang -bundle -arch "$arch" -fobjc-arc -fblocks -fvisibility=hidden \
        -I"$prefs_support/include" \
        -F"$prefs_support/stubs" -F"$SDKROOT/System/Library/PrivateFrameworks" \
        lockscreenrestoreprefs/LSRRootListController.m \
        -framework UIKit -framework Preferences -framework FrontBoardServices -framework SpringBoardServices \
        -o "$work/LockScreenRestorePrefs-$arch"
done

if [ "$archs" = "arm64e" ]; then
    cp "$work/LockScreenRestore-arm64e.dylib" "$tweak_output"
    cp "$work/LockScreenRestorePrefs-arm64e" "$prefs_output"
else
    lipo -create "$work/LockScreenRestore-arm64.dylib" "$work/LockScreenRestore-arm64e.dylib" -output "$tweak_output"
    lipo -create "$work/LockScreenRestorePrefs-arm64" "$work/LockScreenRestorePrefs-arm64e" -output "$prefs_output"
fi
ldid -S "$tweak_output"
ldid -S "$prefs_output"
cp LockScreenRestore.plist "$prefix_stage/Library/MobileSubstrate/DynamicLibraries/LockScreenRestore.plist"
if [ "$APELIN_BOOTSTRAP" = roothide ]; then
    ln -s ../../../usr/lib/DynamicPatches/AutoPatches.dylib \
        "$prefix_stage/Library/MobileSubstrate/DynamicLibraries/LockScreenRestore.dylib.roothidepatch"
fi

prefs_bundle="$prefix_stage/Library/PreferenceBundles/LockScreenRestorePrefs.bundle"
cp lockscreenrestoreprefs/Resources/Info.plist "$prefs_bundle/Info.plist"
cp lockscreenrestoreprefs/Resources/Root.plist "$prefs_bundle/Resources/Root.plist"
cp lockscreenrestoreprefs/Resources/icon.png "$prefs_bundle/Resources/icon.png"
cp lockscreenrestoreprefs/entry.plist "$prefix_stage/Library/PreferenceLoader/Preferences/LockScreenRestorePrefs.plist"
sed "s/^Architecture:.*/Architecture: $APELIN_ARCHITECTURE/" control > "$stage/DEBIAN/control"

dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/"
