#!/bin/bash
# Builds "Simple Battery.app" and installs it to /Applications.
# Re-run after editing SimpleBattery.swift.
#   ./build.sh bundle   only builds build/Simple Battery.app, unsigned (release.sh uses this)
#
# The battery level comes from private IOBluetooth methods, so this cannot go
# to the App Store. To hand it out, release.sh makes a notarized download.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Simple Battery"   # what shows in Finder, Login Items and Activity Monitor
EXE="SimpleBattery"     # executable and source file name
BUNDLE="build/$NAME.app"
LABEL="com.adammackey.simplebattery"            # the login agent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# /Applications is group-writable by admin accounts, so this needs no sudo.
# Falls back to the per-user folder if the account can't write there.
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  echo "No write access to $DEST, installing to ~/Applications instead." >&2
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

rm -rf build
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# Warnings are suppressed because every IOBluetooth call is deprecated API and
# the noise buries real errors. Drop the flag when changing the battery reads.
swiftc -O -suppress-warnings \
  -framework AppKit -framework IOBluetooth \
  -o "$BUNDLE/Contents/MacOS/$EXE" "$EXE.swift"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$EXE</string>
	<key>CFBundleIdentifier</key><string>com.adammackey.simplebattery</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleDisplayName</key><string>$NAME</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<!-- Menu bar only: no Dock icon, no window. -->
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<!-- Not needed for IOBluetooth today, but here so a future OS that asks
	     for Bluetooth permission shows a reason instead of failing. -->
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Reads the battery level your headphones report.</string>
</dict>
</plist>
PLIST

# Redraw the artwork with: swift tools/make-icon.swift
cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

if [[ "${1:-}" == "bundle" ]]; then
  exit 0
fi

# Sign with the fixed self-signed identity when it exists. Ad-hoc signing gives
# the app a new identity every build, and macOS ties the Bluetooth permission to
# that identity, so it would have to be granted again after each rebuild.
IDENTITY="Simple Battery Self Signed"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$BUNDLE" >/dev/null
else
  echo "No '$IDENTITY' identity — signing ad-hoc, so macOS will ask for Bluetooth again." >&2
  echo "Create it once with tools/make-signing-cert.sh." >&2
  codesign --force --sign - "$BUNDLE" >/dev/null
fi

# Unload the agent first. It restarts anything that exits unexpectedly, which
# during a rebuild would mean resurrecting the copy the next line kills.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# A running copy keeps its own menu bar icon, so stop it before replacing.
pkill -f "$NAME.app/Contents/MacOS/$EXE" 2>/dev/null || true
rm -rf "$DEST/$NAME.app"
ditto "$BUNDLE" "$DEST/$NAME.app"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# An install left in the other Applications folder would sit in Finder and
# Spotlight as a second copy of the same app.
if [[ "$DEST" != "$HOME/Applications" && -d "$HOME/Applications/$NAME.app" ]]; then
  "$LSREGISTER" -u "$HOME/Applications/$NAME.app" 2>/dev/null || true
  rm -rf "$HOME/Applications/$NAME.app"
fi
# LaunchServices indexes the copy in build/ as well, and Spotlight will happily
# open that stale one. Unregister and delete it, then register the installed copy.
"$LSREGISTER" -u "$BUNDLE" 2>/dev/null || true
rm -rf "$BUNDLE"
"$LSREGISTER" -f "$DEST/$NAME.app"
# Nudge Spotlight and Finder's icon cache, which otherwise lag a rebuild.
mdimport "$DEST/$NAME.app" 2>/dev/null || true
touch "$DEST/$NAME.app"

# Start at login with a launchd agent rather than SMAppService, because this app
# is ad-hoc signed and launchd doesn't care. System Settings → General → Login
# Items & Extensions still lists it under "Allow in the Background", so it can
# be switched off there. Bootstrapping also starts it now.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/$NAME.app/Contents/MacOS/$EXE</string>
	</array>
	<key>RunAtLoad</key><true/>
	<!-- Restart it only if it dies unexpectedly. Quit from the menu exits 0,
	     so choosing Quit still stays quit until the next login. -->
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key><false/>
	</dict>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
AGENT
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo "Installed $DEST/$NAME.app, starting at login. Dimmed headphones means nothing is connected."
