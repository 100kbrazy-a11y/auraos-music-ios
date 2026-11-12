#!/usr/bin/env bash
# AuraOS Music for iPhone — run this on Fedora. It:
#   1. installs anything missing (Node.js, git, GitHub CLI, iPhone USB support, a QR-code tool)
#   2. checks the app builds
#   3. sends the project to a repo on your GitHub account, where GitHub's free Mac machines compile the iPhone app
#      (Apple only lets iPhone apps be compiled on a Mac, so this part can't happen on Linux)
#   4. downloads AuraOS-Music.ipa into your Downloads folder
#   5. installs iloader, the Linux tool that puts SideStore on your iPhone (only needed once)
#   6. prints a QR code / link: open it on the iPhone (or put it in a Shortcut) and SideStore installs the app
#
#   ./build-ios.sh                  everything above
#   ./build-ios.sh --repo NAME      use a different GitHub repo name (default: auraos-music-ios)
#   ./build-ios.sh --private        make the repo private (the one-tap install link then won't work; see the notes)
#   ./build-ios.sh --no-iloader     skip installing iloader
#   ./build-ios.sh --download-only  don't build again, just fetch the latest AuraOS-Music.ipa
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
PROJECT="$PWD"

REPO_NAME="auraos-music-ios"
VISIBILITY="public"
ILOADER=1 BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_NAME="${2:?--repo needs a name}"; shift ;;
    --private) VISIBILITY="private" ;;
    --no-iloader) ILOADER=0 ;;
    --download-only) BUILD=0 ;;
    -h|--help) sed -n "2,15p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
  shift
done

IPA_NAME="AuraOS-Music.ipa"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/auraos-music-ios"
DOWNLOADS="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
[ -n "$DOWNLOADS" ] && [ "$DOWNLOADS" != "$HOME" ] || DOWNLOADS="$HOME/Downloads"

step() { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { trap - ERR; printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Something went wrong (line $LINENO). The messages above say what — fix that and run ./build-ios.sh again."' ERR
mkdir -p "$CACHE" "$DOWNLOADS"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) NARCH=x64 ;;
  aarch64|arm64) NARCH=arm64 ;;
  *) die "This needs a 64-bit Intel/AMD or ARM computer (found $ARCH)." ;;
esac
command -v dnf >/dev/null || die "This script is made for Fedora (it uses dnf to install things)."

# ------------------------------------------------------------------ 1. packages
step "Checking what's installed"
missing=()
for t in git gh curl unzip rsync qrencode; do command -v "$t" >/dev/null || missing+=("$t"); done
for p in usbmuxd libimobiledevice libimobiledevice-utils fuse-libs; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ ${#missing[@]} -gt 0 ]; then
  note "Installing: ${missing[*]}  (asks for your password)"
  sudo dnf install -y "${missing[@]}" || die "Couldn't install: ${missing[*]}"
fi
note "ok"

node_ok() { command -v node >/dev/null && node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=12)?0:1)' 2>/dev/null; }
if [ "$BUILD" = 1 ]; then
  step "Node.js"
  if ! node_ok && [ -x "$CACHE/node/bin/node" ]; then export PATH="$CACHE/node/bin:$PATH"; fi
  if ! node_ok; then
    note "Installing Node.js from Fedora…"
    sudo dnf install -y nodejs npm >/dev/null 2>&1 || sudo dnf install -y nodejs22 nodejs22-npm >/dev/null 2>&1 || true
  fi
  if ! node_ok; then
    note "Downloading a private copy of Node.js 22 (only used for this)…"
    ver="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | grep -o "node-v22[0-9.]*-linux-$NARCH.tar.xz" | head -1)"
    [ -n "$ver" ] || die "Couldn't find a Node.js download. Check your internet connection."
    curl -fL --retry 3 --progress-bar -o "$CACHE/node.tar.xz" "https://nodejs.org/dist/latest-v22.x/$ver"
    rm -rf "$CACHE/node" && mkdir -p "$CACHE/node" && tar -xJf "$CACHE/node.tar.xz" -C "$CACHE/node" --strip-components=1 && rm -f "$CACHE/node.tar.xz"
    export PATH="$CACHE/node/bin:$PATH"
  fi
  node_ok || die "Node.js 22.12 or newer is needed."
  note "Node $(node -v)"

  # ---------------------------------------------------------------- 2. check it builds (before using GitHub's Mac time)
  step "Checking the app builds"
  if [ ! -d node_modules ] || [ package.json -nt node_modules ]; then npm install --no-audit --no-fund; fi
  npm run build >/dev/null || { npm run build; die "The app didn't build."; }
  note "ok"
fi

# ------------------------------------------------------------------ 3. GitHub
step "GitHub"
if ! gh auth status -h github.com >/dev/null 2>&1; then
  note "Sign in to GitHub (a free account is enough). A browser window opens; paste the code it shows."
  gh auth login -h github.com --git-protocol https --web --scopes workflow
fi
if ! gh api -i user 2>/dev/null | grep -i '^x-oauth-scopes:' | grep -qw workflow; then
  note "GitHub needs one more permission (to add the build recipe to your repo)…"
  gh auth refresh -h github.com -s workflow
fi
gh auth setup-git -h github.com >/dev/null 2>&1 || true
LOGIN="$(gh api user -q .login)"
REPO="$LOGIN/$REPO_NAME"
note "Signed in as $LOGIN"

if ! gh repo view "$REPO" >/dev/null 2>&1; then
  [ "$BUILD" = 1 ] || die "There's no $REPO yet — run ./build-ios.sh without --download-only first."
  note "Creating the repo $REPO ($VISIBILITY)…"
  gh repo create "$REPO" "--$VISIBILITY" --description "AuraOS Music for iPhone (built by GitHub Actions)" >/dev/null
fi
REPO_VIS="$(gh repo view "$REPO" --json visibility -q .visibility | tr 'A-Z' 'a-z')"

RUN_ID=""
if [ "$BUILD" = 1 ]; then
  WORK="$CACHE/repo-$REPO_NAME"
  if [ ! -d "$WORK/.git" ]; then
    rm -rf "$WORK"
    git clone -q "https://github.com/$REPO.git" "$WORK" 2>/dev/null || { mkdir -p "$WORK" && git -C "$WORK" init -q && git -C "$WORK" remote add origin "https://github.com/$REPO.git"; }
  fi
  git -C "$WORK" fetch -q origin 2>/dev/null || true
  if git -C "$WORK" rev-parse -q --verify origin/main >/dev/null; then git -C "$WORK" checkout -q -B main origin/main; else git -C "$WORK" checkout -q -B main; fi
  rsync -a --delete --exclude .git --exclude node_modules --exclude dist --exclude build --exclude '*.ipa' \
    --exclude ios/App/Pods --exclude ios/App/App/public "$PROJECT/" "$WORK/"
  git -C "$WORK" config user.name >/dev/null || git -C "$WORK" config user.name "$LOGIN"
  git -C "$WORK" config user.email >/dev/null || git -C "$WORK" config user.email "$(gh api user -q .id)+$LOGIN@users.noreply.github.com"
  git -C "$WORK" add -A
  START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if git -C "$WORK" diff --cached --quiet && git -C "$WORK" rev-parse -q --verify origin/main >/dev/null; then
    note "No changes since the last build — building again anyway."
    git -C "$WORK" push -q origin main 2>/dev/null || true
    gh workflow run ios.yml -R "$REPO" --ref main
  else
    git -C "$WORK" commit -qm "AuraOS Music for iPhone — $(date '+%Y-%m-%d %H:%M')"
    note "Uploading the project…"
    git -C "$WORK" push -q -u origin main
  fi
  SHA="$(git -C "$WORK" rev-parse HEAD)"

  # ---------------------------------------------------------------- 4. wait for the build
  step "Building the iPhone app on GitHub (about 5–10 minutes)"
  note "You can also watch it at https://github.com/$REPO/actions"
  for _ in $(seq 1 60); do
    RUN_ID="$(gh run list -R "$REPO" -w ios.yml -L 10 --json databaseId,headSha,createdAt \
      -q "[.[] | select(.headSha == \"$SHA\" and .createdAt >= \"$START\")][0].databaseId // empty" 2>/dev/null || true)"
    [ -n "$RUN_ID" ] && break
    sleep 3
  done
  [ -n "$RUN_ID" ] || die "GitHub didn't start the build. Open https://github.com/$REPO/actions — if Actions are turned off, turn them on and run this again."
  if ! gh run watch "$RUN_ID" -R "$REPO" -i 15 --exit-status; then
    echo; gh run view "$RUN_ID" -R "$REPO" --log-failed 2>/dev/null | tail -60 || true
    die "The iPhone build failed (log above, full log: https://github.com/$REPO/actions/runs/$RUN_ID)."
  fi
fi

# ------------------------------------------------------------------ 5. download the .ipa
step "Downloading $IPA_NAME"
if [ -z "$RUN_ID" ]; then
  RUN_ID="$(gh run list -R "$REPO" -w ios.yml -s success -L 1 --json databaseId -q '.[0].databaseId // empty')"
  [ -n "$RUN_ID" ] || die "No finished build yet — run ./build-ios.sh without --download-only."
fi
tmp="$(mktemp -d)"
gh run download "$RUN_ID" -R "$REPO" -n AuraOS-Music-ipa -D "$tmp"
mv -f "$tmp/$IPA_NAME" "$DOWNLOADS/$IPA_NAME"; rm -rf "$tmp"
note "Saved $DOWNLOADS/$IPA_NAME ($(du -h "$DOWNLOADS/$IPA_NAME" | cut -f1))"

# ------------------------------------------------------------------ 6. iloader (puts SideStore on the iPhone, once)
if [ "$ILOADER" = 1 ]; then
  step "iloader (installs SideStore on your iPhone)"
  if command -v iloader >/dev/null || rpm -q iloader >/dev/null 2>&1; then
    note "Already installed — open it from your apps menu."
  else
    case "$ARCH" in x86_64|amd64) rx='(x86_64|amd64)' ;; *) rx='(aarch64|arm64)' ;; esac
    assets="$(gh release view -R nab138/iloader --json assets -q '.assets[].name' 2>/dev/null || true)"
    rpmf="$(grep -E "$rx.*\.rpm$" <<<"$assets" | head -1 || true)"
    appimg="$(grep -E "$rx.*\.AppImage$" <<<"$assets" | head -1 || true)"
    if [ -n "$rpmf" ]; then
      gh release download -R nab138/iloader -p "$rpmf" -D "$CACHE" --clobber
      sudo dnf install -y "$CACHE/$rpmf" && note "Installed — open \"iloader\" from your apps menu."
    elif [ -n "$appimg" ]; then
      gh release download -R nab138/iloader -p "$appimg" -D "$DOWNLOADS" --clobber
      chmod +x "$DOWNLOADS/$appimg"
      note "Saved $DOWNLOADS/$appimg — double-click it (or run it from a terminal) to open iloader."
    else
      note "Couldn't find an iloader download for this computer. Get it from https://github.com/nab138/iloader/releases"
    fi
  fi
  sudo systemctl enable --now usbmuxd >/dev/null 2>&1 || true   # Fedora usually starts this by itself when an iPhone is plugged in
fi

# ------------------------------------------------------------------ 7. how to put it on the iPhone
LINK="sidestore://install?url=https://github.com/$REPO/releases/latest/download/$IPA_NAME"
GUIDE="$DOWNLOADS/AuraOS-Music-iPhone-setup.txt"
cat > "$GUIDE" <<TXT
AuraOS Music on iPhone
======================

ONE-TIME SETUP (SideStore)
1. Plug the iPhone into this computer with a cable, unlock it and tap "Trust".
2. Open iloader, sign in with your Apple ID (a free one works) and click "Install SideStore".
3. On the iPhone:
   - Settings > General > VPN & Device Management: tap your Apple ID and trust it.
   - Settings > Privacy & Security > Developer Mode: turn it on (the iPhone restarts).
   - Install "LocalDevVPN" from the App Store. SideStore uses it to install and refresh apps without a computer.
4. Open SideStore and sign in with the same Apple ID.
   After this you don't need the computer any more.

INSTALL AURAOS MUSIC (and update it later the same way)
Option A: scan the QR code the script showed with the iPhone camera, then open it in SideStore.
Option B: make a Shortcut that installs it:
   1. Open Shortcuts and tap +.
   2. Add the action "Open URLs" and paste this as the URL:
      $LINK
   3. Name it "Install AuraOS Music". Optionally, share it and choose Add to Home Screen.
   Running it opens SideStore, which downloads and installs AuraOS Music as a real app.
   Run it again after a new build to update; your music and settings stay.
Option C: send $IPA_NAME to the iPhone (for example AirDrop it from a Mac, or save it to iCloud Drive),
          then share it from the Files app to SideStore.

KEEPING IT RUNNING
Apps installed with a free Apple ID last 7 days. SideStore refreshes them for you: open it and tap "Refresh All",
or have it happen by itself: Shortcuts > Automation > + > Time of Day (daily) > the SideStore action "Refresh All Apps".
A free Apple ID can have 3 sideloaded apps at once (SideStore counts as one).

NEW BUILDS
Run ./build-ios.sh again after you change anything. It uploads the changes, waits for GitHub to build,
and downloads the new $IPA_NAME. Then run your Shortcut on the iPhone to update.
TXT
if [ "$REPO_VIS" != "public" ]; then
  cat >> "$GUIDE" <<TXT

NOTE: your repo $REPO is private, so the one-tap link (Options A and B) can't download the app.
Use Option C, or make the repo public:  gh repo edit $REPO --visibility public --accept-visibility-change-consequences
TXT
fi

step "Done"
note "App:   $DOWNLOADS/$IPA_NAME"
note "Steps: $GUIDE"
if [ "$REPO_VIS" = "public" ]; then
  echo
  note "Install link — scan this with the iPhone camera once SideStore is set up:"
  qrencode -t ansiutf8 -m 2 "$LINK" | sed 's/^/    /'
  note "$LINK"
fi
echo
note "First time? Plug in the iPhone, open iloader and click \"Install SideStore\", then follow the steps file."
