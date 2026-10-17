#!/usr/bin/env bash
# Build Paddington.app, sign it with a stable identity (keeps Accessibility/Bluetooth grants across rebuilds),
# install to ~/Applications and link the CLI to ~/.local/bin/paddington.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${PADDINGTON_APP_DIR:-$HOME/Applications}"
APP="$DEST/Paddington.app"
IDENTITY="${PADDINGTON_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"

swift build -c release --product paddington
swift build -c release --product padbeat
BIN="$(swift build -c release --show-bin-path)/paddington"
BEAT="$(swift build -c release --show-bin-path)/padbeat"

AGENT="com.pkronstrom.padctl.agent"
FINAL="$APP"
# Build the new bundle beside the installed one and swap it in at the end. The running app is never
# stopped or started from here: it notices the new version and relaunches itself cleanly. (An app started
# from an agent's sandboxed shell can't see tmux.)
APP="$DEST/.Paddington.staging.app"
rm -rf "$APP"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/paddington"
cp "$BEAT" "$APP/Contents/MacOS/padbeat"
rm -rf "$APP/Contents/Resources/config"
cp -R config "$APP/Contents/Resources/config"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.pkronstrom.padctl</string>
  <key>CFBundleName</key><string>Paddington</string>
  <key>CFBundleDisplayName</key><string>Paddington</string>
  <key>CFBundleExecutable</key><string>paddington</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSEnvironment</key><dict><key>PADDINGTON_APP</key><string>1</string></dict>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Paddington connects to your MIDI pad over Bluetooth.</string>
  <key>NSMicrophoneUsageDescription</key><string>Hold an empty pad to record a short sound for it (the mini-sampler).</string>
  <key>NSAppleEventsUsageDescription</key><string>Paddington asks iTerm which terminal session is focused, to send keys to the right tmux pane.</string>
</dict>
</plist>
PLIST

# Start at login (menu): a launchd agent that also restarts paddington after a crash; a clean quit stays quit.
cat > "$APP/Contents/Library/LaunchAgents/$AGENT.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT</string>
  <key>BundleProgram</key><string>Contents/MacOS/paddington</string>
  <key>ProgramArguments</key><array><string>paddington</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>PADDINGTON_APP</key><string>1</string></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>com.pkronstrom.padctl</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier com.pkronstrom.padbeat --options runtime "$APP/Contents/MacOS/padbeat"
  codesign --force --sign "$IDENTITY" --identifier com.pkronstrom.padctl --options runtime \
    --entitlements /dev/stdin "$APP" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.device.bluetooth</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENT
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - "$APP/Contents/MacOS/padbeat"
  codesign --force --sign - "$APP"
  echo "WARNING: ad-hoc signed — permissions will need re-granting after every rebuild"
fi

# swap: the running process keeps its (now unlinked) files; a new launch gets the new ones
rm -rf "$FINAL.old"
[[ -d "$FINAL" ]] && mv "$FINAL" "$FINAL.old"
mv "$APP" "$FINAL"
rm -rf "$FINAL.old"
APP="$FINAL"

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/paddington" "$HOME/.local/bin/paddington"
# `padctl` (the old name) stays as a short alias; hooks installed under that name keep working
ln -sf "$APP/Contents/MacOS/paddington" "$HOME/.local/bin/padctl"
echo "installed: $APP"
echo "cli:       $HOME/.local/bin/paddington (also: padctl)"

# Paddington used to be called padctl (same bundle id, so permissions and settings carry over). Once: let the
# old app quit, move its config folder (leaving a link at the old path), drop its socket folder and bundle, then
# start the new app.
OLD="$DEST/Padctl.app"
if [[ -d "$OLD" ]]; then
  if pgrep -f "$OLD/Contents/MacOS/padctl" >/dev/null 2>&1; then
    # Its update check (every second) sees a changed executable and quits cleanly to relaunch; the stub that
    # changed it is gone before that relaunch, so nothing starts again.
    mv "$OLD" "$DEST/.Padctl.old.app"
    mkdir -p "$OLD/Contents/MacOS" && : > "$OLD/Contents/MacOS/padctl"
    for _ in $(seq 50); do pgrep -f "$OLD/Contents/MacOS/padctl" >/dev/null 2>&1 || break; sleep 0.1; done
    rm -rf "$OLD"
    if pgrep -f "$OLD/Contents/MacOS/padctl" >/dev/null 2>&1; then
      mv "$DEST/.Padctl.old.app" "$OLD"
      echo "Padctl (the old app) didn't quit: quit it from its menu, then run this script again." >&2
      exit 1
    fi
    rm -rf "$DEST/.Padctl.old.app"
  fi
  if [[ -d "$HOME/.config/padctl" && ! -L "$HOME/.config/padctl" && ! -e "$HOME/.config/paddington" ]]; then
    mv "$HOME/.config/padctl" "$HOME/.config/paddington"
    ln -s "$HOME/.config/paddington" "$HOME/.config/padctl"
    echo "config:    ~/.config/padctl → ~/.config/paddington (a link stays at the old path)"
  fi
  rm -rf "$HOME/Library/Application Support/padctl"
  rm -rf "$OLD"
  echo "removed:   $OLD"
  /usr/bin/open "$APP"
  echo "started:   $APP"
elif pgrep -f "$APP/Contents/MacOS/paddington" >/dev/null 2>&1; then
  echo "the running app restarts itself with the new version"
fi
