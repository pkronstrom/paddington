#!/usr/bin/env bash
# Build Padctl.app, sign it with a stable identity (keeps Accessibility/Bluetooth grants across rebuilds),
# install to ~/Applications and link the CLI to ~/.local/bin/padctl.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${PADCTL_APP_DIR:-$HOME/Applications}"
APP="$DEST/Padctl.app"
IDENTITY="${PADCTL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"

swift build -c release --product padctl
swift build -c release --product padbeat
BIN="$(swift build -c release --show-bin-path)/padctl"
BEAT="$(swift build -c release --show-bin-path)/padbeat"

AGENT="com.pkronstrom.padctl.agent"
FINAL="$APP"
# Build the new bundle beside the installed one and swap it in at the end. The running app is never
# stopped or started from here: it notices the new version and relaunches itself cleanly. (An app started
# from an agent's sandboxed shell can't see tmux.)
APP="$DEST/.Padctl.staging.app"
rm -rf "$APP"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/padctl"
cp "$BEAT" "$APP/Contents/MacOS/padbeat"
rm -rf "$APP/Contents/Resources/config"
cp -R config "$APP/Contents/Resources/config"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.pkronstrom.padctl</string>
  <key>CFBundleName</key><string>Padctl</string>
  <key>CFBundleDisplayName</key><string>Padctl</string>
  <key>CFBundleExecutable</key><string>padctl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSEnvironment</key><dict><key>PADCTL_APP</key><string>1</string></dict>
  <key>NSBluetoothAlwaysUsageDescription</key><string>padctl connects to your MIDI pad over Bluetooth.</string>
  <key>NSAppleEventsUsageDescription</key><string>padctl asks iTerm which terminal session is focused, to send keys to the right tmux pane.</string>
</dict>
</plist>
PLIST

# Start at login (menu): a launchd agent that also restarts padctl after a crash; a clean quit stays quit.
cat > "$APP/Contents/Library/LaunchAgents/$AGENT.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT</string>
  <key>BundleProgram</key><string>Contents/MacOS/padctl</string>
  <key>ProgramArguments</key><array><string>padctl</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>PADCTL_APP</key><string>1</string></dict>
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
ln -sf "$APP/Contents/MacOS/padctl" "$HOME/.local/bin/padctl"
echo "installed: $APP"
echo "cli:       $HOME/.local/bin/padctl"
if pgrep -f "$APP/Contents/MacOS/padctl" >/dev/null 2>&1; then echo "the running app restarts itself with the new version"; fi
