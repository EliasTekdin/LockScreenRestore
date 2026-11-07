# LockScreenRestore

Brings the iOS 15 lock screen back to iOS 16: clock, notifications, music player, unlock animation, live and dynamic wallpapers and the old **Settings → Wallpaper** page.

<p align="center">
  <img src="screenshots/lockscreen.png" width="200" alt="Lock screen with the iOS 15 clock, padlock and Focus pill">
  &nbsp;
  <img src="screenshots/notifications.png" width="200" alt="iOS 15 notification cards listed under the clock">
  &nbsp;
  <img src="screenshots/music.png" width="200" alt="iOS 15 music player with large artwork, app icon, AirPlay button and volume slider">
</p>

> Dynamic Island support is device-dependent; the current lock glyph placement has been adjusted for Dynamic Island layouts, but models and iOS versions still need individual testing.

## What it changes

Every part has its own switch, so you can mix iOS 15 and iOS 16.

### 🕘 Clock
- Thin iOS 15 clock in iOS 15's own font, the date below it, plain white
- Big padlock that stays open after Face ID
- No depth effect and no lock screen widgets
- The charging battery appears where the clock is

### 🌙 Focus
- The Focus pill sits under the date instead of the Focus name at the bottom

### 🔔 Notifications
- Listed right under the clock, always as a list
- iOS 15 card shape: 18.5 pt corners, tighter padding
- **Notification Centre** and its ✕ only appear when you swipe up
- Pulling down anywhere on the lock screen opens search, like iOS 15; the list and the Focus pill stay where they are

### 🎵 Music player
- The iOS 15 layout with the sizes of iOS 15's player: large artwork with the app's icon, device name above the title, AirPlay next to it
- Progress bar with a knob, bigger buttons and the **volume slider**

### 🔓 Unlock animation
- The home screen wallpaper follows your swipe, and the lock screen only blurs when the two wallpapers differ

### 🖼️ Wallpaper
- **Live** wallpapers: press and hold the lock screen to play
- **Dynamic** wallpapers: iOS 15's animated bubbles, drawn by iOS 15's own view
- **Perspective Zoom** as on iOS 15, and a Light and a Dark version that follow the system appearance
- Different wallpapers for the lock screen and the home screen
- **Settings → Wallpaper** is the iOS 15 page again: *Choose a New Wallpaper* with Dynamic, Stills, Live and your photo albums, iOS's own preview with **Set Lock Screen / Home Screen / Both**, and *Dark Appearance Dims Wallpaper*
- On iPhone Plus models the wallpaper turns with the home screen

### 🏠 Home screen
- The lighter iOS 15 shadow under the app names (iOS 16 draws it much darker)

## Settings

**Settings → Tweaks → LockScreenRestore** has one switch per part (Clock, Focus, Notifications, Music Player, Unlock Animation, Icon Label Shadows, Live Wallpaper), all on by default, and:

- **Clock Size**: 0.7 to 1.5 times iOS 15's size
- **Fix Positions**: shows the detected iPhone and recalculates all positions
- **Reset to Defaults**

Switches apply after **Apply (Respring)**. Wallpapers are picked in **Settings → Wallpaper**.

## Wallpapers

Apple's wallpapers are copyrighted and not part of this repository or the package.

- **Stills and Live**: *Choose a New Wallpaper* lists Apple's iOS 14/15 wallpapers under **Available to Download** (from the [SniperGER/iOS-Wallpapers](https://github.com/SniperGER/iOS-Wallpapers) archive). Tap one to download it and open the preview.
- **Dynamic**: no download, iOS 16 still ships them.
- **Photos** from your library work too, with Move & Scale.

To add one by hand, put `Light.heic` and `Dark.heic` (plus `Light.mov` and `Dark.mov` for a live wallpaper) into a folder in `/var/mobile/Library/LockScreenRestore/Wallpapers/`. The folder's name is the wallpaper's name.

## Compatibility

The tweak targets iOS 16 and later and has RootHide and rootless package builds. It is intended for iPhone lock screens; behavior can differ by device and iOS version. The current Dynamic Island lock-glyph adjustment was reported fixed by a user on an iPhone 15 Pro Max running iOS 17.1.1, but that is not a substitute for testing each feature and device.

## Installation

Add the repo to Sileo or Zebra and install LockScreenRestore:

```
https://aronsz26.github.io/
```

Or download the `.deb` from the [releases page](../../releases) and open it with Sileo, Zebra or Filza. PreferenceLoader is installed automatically.

If your iPhone lands in Safe Mode, turn the part that caused it off in the tweak's settings or uninstall the package, and please [open an issue](../../issues).

## Known limitations

- Device-specific positioning can vary, especially on Dynamic Island models; validate the Lock Screen on each target device and iOS release.
- Landscape on Plus models is new; the direction of Perspective Zoom and of the bubbles' motion is untested there.
- On iPhones with a home button, the dock can briefly show iOS's own wallpaper while the home screen rotates; it is right again once the turn is done.
- Live wallpapers play through the tweak's own player, not iOS 15's.
- With Live Wallpaper on, the long press no longer opens iOS 16's lock screen editor.
- The home screen preview in Settings → Wallpaper is a small screenshot taken when you unlock; it stays on your iPhone.
- Downloads depend on the wallpaper archive being online.
- Other tweaks that change the same parts of the lock screen may conflict.

## Building

In Apelin, build this workspace with its external `build.sh` script. Build RootHide and rootless separately; RootHide produces an `iphoneos-arm64e` package and rootless produces a universal `iphoneos-arm64` package with arm64 and arm64e slices. Apelin provides the prepared toolchain, SDK and injection-framework stubs used by the script.

The resulting `.deb` is a build artifact managed by Apelin and is not checked into this source repository. Use the project's **Distribute…** action to export a package for the selected bootstrap.

The packaged Objective-C sources are `Tweak.m`, `LSRWallpaperPane.m` and `DebugTools.m`; `lockscreenrestoreprefs/` contains the Settings pane. The legacy Theos Makefiles and `.xm` source are not used by the Apelin builder.

## How it works

iOS 16 still ships much of iOS 15, mostly for the iPad, and the tweak uses those parts where they exist: the bubbles view and the still wallpaper view with Perspective Zoom (`PBUIBokehWallpaperView`, `PBUIStaticWallpaperView`), the wallpaper preview (`SBSUIWallpaperPreviewViewController`), the clock's font, the unlock transition's settings and the drawing of the shadow under app names.

Where iOS 16 has nothing left, like the music player's layout or the notification cards, the tweak adjusts iOS 16's views to the sizes read from a real iOS 15 lock screen. Clock size and position per iPhone follow iOS 15's own rules and are worked out each time SpringBoard starts.

## License

[MIT](LICENSE)
