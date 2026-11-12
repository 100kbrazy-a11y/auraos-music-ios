# AuraOS Music for iPhone

The same app as the Android version: every feature, gesture, and setting is the same. The look is restyled for iOS 26 with
Liquid Glass: the bubble, the tab pill, the tab highlight, sheets, toasts, chips, and the player's buttons are clear, bright
glass with a light-catching rim.

## Build and install (Fedora)

```bash
cd ~/Downloads && rm -rf auraos-music-ios && unzip auraos-music-ios.zip && cd auraos-music-ios && ./build-ios.sh
```

What it does:

1. Installs anything missing: Node.js, git, the GitHub CLI, iPhone USB support (usbmuxd, libimobiledevice), and qrencode.
2. Checks the app builds.
3. Puts the project in a repo on your GitHub account (`auraos-music-ios`, public). Apple only lets iPhone apps
   be compiled on a Mac, so GitHub's free Mac machines build it (`.github/workflows/ios.yml`, about 5–10 minutes).
4. Downloads **AuraOS-Music.ipa** to your Downloads folder.
5. Installs **iloader**, which puts SideStore on your iPhone over USB (one time only).
6. Prints a QR code and the install link, and saves **AuraOS-Music-iPhone-setup.txt** in Downloads with every step.

The Shortcut that installs the app is a single **Open URLs** action with this link:

```
sidestore://install?url=https://github.com/<your-github-name>/auraos-music-ios/releases/latest/download/AuraOS-Music.ipa
```

Run it again after a new build to update. Your library and settings stay.

## Real Liquid Glass (iOS 26)

The floating parts are native iPhone views using Apple's own Liquid Glass (`ios-native/NativeChrome.swift`):

- the media bar + tabs bubble (upright), and the tab pill + media bubble (sideways), with the same gestures:
  tap to open, swipe sideways to skip, drag up to grow the player, touch-and-slide the tab highlight, tucking
- play / pause is a system glass button; the glass picks up the song's colour
- while your finger is on the tabs, a clear glass lens rides over the icons and titles, bending them, and the tab under it grows a little
- the top bar: the page's buttons are glass (icon buttons share one capsule; Play is tinted), and once you scroll a full-width
  glass bar with the page title fades in and the page scrolls under it
- the bubble and the top bar step aside while a sheet (filters, EQ…) or selection mode is open
- Settings is a real iOS screen: it slides in like a pushed page, with the system's glass back button (and edge swipe),
  native switches, the crossfade slider, a segmented Scroll Timers control and an EQ preset menu with its graph
- Add Music Pack uses Apple's Files browser too, and packs are read from disk piece by piece (never loaded whole)
- song menus, confirmations and rename boxes are the system's glass menus and alerts
- Add Songs opens Apple's Files browser, showing music files only
- Settings › Diagnostics shows what the app did recently (imports step by step, errors), with a Copy button

The web screens underneath still decide sizes and positions, and the visualizer still draws under the glass.
On iOS versions before 26 the same views use the standard frosted blur.

## What's different from Android

- Background playback, lock-screen and Control Center controls; plays with the silent switch on.
- Songs are stored as real files inside the app (not in the web view's database), so big libraries and packs work.
- Music packs you export are saved in Files › On My iPhone › AuraOS Music.
- No hardware back button: use the back arrow, or swipe right on a page.
- Music servers on your home network (Navidrome / Subsonic over http) are allowed.

## Files

- `ios/`: the native Xcode project (Capacitor). `scripts/patch-ios.mjs` adds background audio, Files access, and the dark status bar.
- `.github/workflows/ios.yml`: the build on GitHub.
- `build-ios.sh`: the one command above.
