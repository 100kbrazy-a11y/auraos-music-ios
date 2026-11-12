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

## What's different from Android

- Background playback, lock-screen and Control Center controls; plays with the silent switch on.
- Music packs you export are saved in Files › On My iPhone › AuraOS Music.
- No hardware back button: use the back arrow, or swipe right on a page.
- Music servers on your home network (Navidrome / Subsonic over http) are allowed.

## Files

- `ios/`: the native Xcode project (Capacitor). `scripts/patch-ios.mjs` adds background audio, Files access, and the dark status bar.
- `.github/workflows/ios.yml`: the build on GitHub.
- `build-ios.sh`: the one command above.
