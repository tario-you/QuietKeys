#!/bin/zsh
# Builds QuietKeys.app into ~/Applications and starts it at login.
set -e
cd "${0:A:h}"
APP="$HOME/Applications/QuietKeys.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/QuietKeys"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>live.opentrade.quietkeys</string>
<key>CFBundleName</key><string>QuietKeys</string>
<key>CFBundleExecutable</key><string>QuietKeys</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# A real identity keeps the Accessibility grant across rebuilds; ad-hoc signing would not.
# Uses your first Apple Development identity, else ad-hoc. Override with SIGN_ID=...
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${SIGN_ID:--}" --identifier live.opentrade.quietkeys "$APP"
AGENT="$HOME/Library/LaunchAgents/live.opentrade.quietkeys.plist"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>live.opentrade.quietkeys</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/QuietKeys</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardErrorPath</key><string>/tmp/quietkeys.err</string>
</dict></plist>
PLIST
launchctl bootout gui/$UID/live.opentrade.quietkeys 2>/dev/null || true
# bootout returns before the job is gone; wait or bootstrap fails with error 5.
while launchctl print gui/$UID/live.opentrade.quietkeys &>/dev/null; do sleep 0.2; done
launchctl bootstrap gui/$UID "$AGENT"
echo "installed $APP"
