# AuraOS Music for Android

## Build it (one command)

```bash
cd ~/Downloads
unzip auraos-music-android.zip
cd auraos-music-android
./build-android.sh
```

The command:

- installs or downloads everything it needs (Node.js 22, Java 17, the Android SDK and Gradle);
- builds and signs the app;
- saves **`AuraOS-Music.apk` in your Downloads folder** and highlights it in your file manager.

The first run downloads about 1–2 GB and takes a few minutes. Later runs take about a minute.

Options:

- `./build-android.sh --install` also installs the app on a phone plugged in by USB with USB debugging turned on.
- `./build-android.sh --clean` rebuilds the Android project from scratch.

## Put it on your phone

1. Copy `AuraOS-Music.apk` to the phone, by USB or through any cloud drive.
2. Open it on the phone.
3. Android asks once whether to allow installing apps from that source. Allow it.

Updates install over the old version, because every build is signed with your own key. The key is in `~/.config/auraos-music/`; keep `android-release.jks` and `android-keystore.pass`.

## What's in it

- **Library:** Albums, Artists, Songs and Playlists. Swipe left or right anywhere to switch tabs. **Favorite Songs** is the first row of Playlists.
- **The bubble:** the media controls and the tabs share one floating glass bubble at the bottom, with a visualizer playing behind them. Drag the tab highlight between tabs; it snaps, stretches and wobbles into place.
- **Media controls:** swipe them left or right to skip or go back. Tap to open Now Playing — it grows out of the bubble with a springy bounce — or drag the bubble up and the player grows with your finger, stage by stage.
- **Adding music:** **Add Songs** picks music files from your phone. Their tags and covers are read, and they're kept organized as Artist / Album / NN Title. Missing albums, years, genres and covers are filled in online (you can turn this off in Settings).
- **Music packs:** **Share as Music Pack** (songs, albums, playlists or a selection) makes `Title-musicpack.zip` in Downloads with a Share button; **Add Music Pack** adds one with all its info, covers and playlist. Packs work both ways with the desktop app.
- **Browse:** search your whole library (songs, albums, artists, genres), with your recent searches underneath.
- **Mixes:** play a song you searched for, or an album with fewer than 5 songs, and the app says “Creating mix…” and adds similar songs from your library after it.
- **Filters:** the filter button next to search (Albums, Artists, Songs, Favorites) narrows by genre, artist, decade, song length, favorites only and recently added. Active filters show as chips you can remove.
- **Genres:** Favorites has genre buttons (pick several), and **Find Genres** (Settings, or the button on Favorites) looks up genres online for songs that don't have one.
- **Hold a song or album** for its menu, including **Look Up Info…** (search iTunes and Deezer, pick a result, tick the fields to use) and **Select** for multi-select.
- **Now Playing:** album-colour background that crossfades between songs, a visualizer behind the controls, and a glow that reacts to the bass. Swipe the cover left/right to skip, tap it to flip it for song details, and drag it down to shrink the player back into the bubble — slowly to watch every stage, or flick it.
- **Lyrics:** synced lyrics from LRCLIB — four lines with the third one current and a soft glow behind it. Scroll or flick through them; they glide back to the current line after 1.5 s (Settings → Scroll Timers). **Earlier / Later** fix the timing, **Wrong lyrics?** picks others, and tapping the cover leaves lyrics.
- **Equalizer:** the same presets as the desktop app, loudness-matched to Flat.
- **Crossfade:** 0–12 seconds (Settings → Playback). The song that's ending stays on screen until it finishes. With nothing up next, a song just repeats.
- **Sideways:** the tabs become a floating vertical pill on the right and the media controls a bubble along the bottom. While you scroll (and in Settings) the media bar shrinks to its album cover and slides in under the tab pill (switching tabs keeps it tucked and restarts the Scroll Timer). As it tucks, the cover zooms in to fill the bubble; swipe it to skip or go back. Tucked, it shows a 5-bar visualizer and a squished progress bar. **Keep Media Bar Tucked** (Settings → Playback) keeps it there for good. Headers are compact with Play/Shuffle in the top bar, and in lyrics mode the song name sits at the top with the lyrics to the right of the cover.
- **Edge to edge:** album colours run behind the status bar and navigation bar.
- **Background playback:** music keeps playing with the screen off, with lock-screen and notification controls.
- **Motion effects:** sliding pages and a living background. You can turn them off in Settings.

CD ripping (Disc Studio) is desktop-only, because phones can't read CDs.

## For developers

- `npm run dev` runs the app in a browser.
- `npm run build` builds the web part into `dist/`.
- `android/` is the Capacitor 6 Android project. `scripts/patch-android.mjs` sets its permissions and theme.
