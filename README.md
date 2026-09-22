# Simple Battery

A menu bar battery icon showing the charge of the connected Bluetooth headset, with the
percentage as an option. Nothing else: no window and no Dock icon. With nothing
connected it stays put as a dimmed headphones glyph. Click it for "Show Percentage" and
Quit.

The icon is the nearest quarter-full battery glyph (`battery.25percent` and friends,
falling back to the pre-rename `battery.25` names). The percentage toggle is remembered
between launches and can also be set by hand:

```sh
defaults write com.adammackey.simplebattery showPercent -bool true
```

## Layout

| Path | What |
|---|---|
| `SimpleBattery.swift` | The whole app: status item, refresh timer, battery read |
| `build.sh` | Builds the bundle, signs it, installs to `/Applications`, starts it at login |
| `release.sh` | Makes the notarized download, signed with Developer ID |
| `tools/make-icon.swift` | Draws `AppIcon.icns`: a white headphones glyph on a green squircle |
| `tools/make-signing-cert.sh` | Creates the self-signed identity `build.sh` signs with, once |
| `AppIcon.icns` | The artwork `build.sh` copies into the bundle |

After a Quit, start it again by double-clicking `/Applications/Simple Battery.app` or
searching Spotlight for "Simple Battery". It comes back by itself at the next login.
`build.sh` unregisters and deletes the copy in `build/`, because LaunchServices indexes
that one too and Spotlight will otherwise open the stale build.

## Install

Download the zip from [Releases](../../releases), unzip it, and drag
**Simple Battery** to Applications. Open it, and allow Bluetooth when macOS asks.
A downloaded copy doesn't start itself at login, so add it in System Settings →
General → Login Items.

Or build it (you'll need Xcode or the Command Line Tools). This also sets it up
to start at login:

```sh
git clone https://github.com/AdamMackey/simple-battery.git
cd simple-battery
./build.sh
```

To see what it reads:

```sh
SIMPLE_BATTERY_DEBUG=1 "/Applications/Simple Battery.app/Contents/MacOS/SimpleBattery"
```

That prints the connected devices and the level it picked, on stderr.

## Where the number comes from

`system_profiler SPBluetoothDataType` and `ioreg` report no battery for these headsets.
`bluetoothd` does keep the level the headset sends over HFP, and private
`IOBluetoothDevice` methods read it back: `batteryPercentSingle` for headphones,
`batteryPercentLeft` / `batteryPercentRight` for earbuds, `batteryPercentCombined`.
Zero from those means "no report", not an empty battery.

Private API, so an OS update can rename them. Each call goes through an
`@objc optional` protocol, which is a `respondsToSelector` check, and a missing value
hides the icon rather than crashing. If the icon stops appearing while headphones are
connected, run the debug command above: `level=none` means the method names moved.

The level refreshes every 30 seconds, when the menu opens, a few seconds after the radio
state changes, and again after the Mac wakes. It only moves when the headset sends a new
value, so expect steps rather than a smooth slide.

## Why it stays in the menu bar when idle

An earlier version hid the icon with nothing connected. That went wrong twice over:
macOS App Naps a menu bar app whose icon is idle, which stops the refresh timer, so a
headset reconnecting went unnoticed — and clicking the app in Finder looked dead,
because LaunchServices just reactivates the copy already running rather than starting a
visible one.

So: the icon never hides while the app runs, `ProcessInfo.beginActivity` opts out of App
Nap for the life of the process, the timer runs in `.common` mode, and the launch agent
carries `KeepAlive`/`SuccessfulExit=false` so an unexpected death restarts it while Quit
(a clean exit) still stays quit.

## Not App Store material

Private API use fails App Review, and public macOS APIs expose no battery level for
third-party headsets. App Store apps that advertise Sony/Bose/Anker support lean on what
macOS already surfaces, which for these headsets is nothing. So it ships as a notarized
direct download instead, on the Releases page.

## Why the reading happens in a helper process

An IOBluetooth session held open inside a long-running app goes bad in at least three
ways, all of them seen here:

- With no Bluetooth permission, `IOBluetoothDevice.pairedDevices()` blocks forever rather
  than failing. The app stays alive with a healthy event loop, no icon and no refreshes.
- After the radio is switched off and on, the session keeps reporting devices as
  connected while every battery selector returns zero, permanently.
- The same wedge turned up once more with no radio toggle involved.

Nothing resets that from inside the process. So this binary reads the level in `--read`
mode and exits, and the app spawns it every 30 seconds with a 10 second timeout, never
calling IOBluetooth itself. A read that hangs kills a child process, not the icon, and a
fresh process cannot inherit a stale session. By hand:

```sh
"/Applications/Simple Battery.app/Contents/MacOS/SimpleBattery" --read
# 70	Your Headphones
```

The app still needs Bluetooth permission, in System Settings → Privacy & Security →
Bluetooth; the helper inherits it from the bundle.

## Signing

`build.sh` signs with a fixed self-signed identity, "Simple Battery Self Signed", created
once by `tools/make-signing-cert.sh` and kept in the login keychain. macOS ties the
Bluetooth grant to the app's designated requirement, and this keeps that requirement
identical across rebuilds:

```
designated => identifier "com.adammackey.simplebattery" and certificate leaf = H"cea43c46…"
```

Ad-hoc signing changed it on every build, so the permission had to be granted again each
time — and a forgotten grant looks exactly like the app being broken. `security
find-identity` reports the certificate as `CSSMERR_TP_NOT_TRUSTED`, which is expected and
harmless: trust is Gatekeeper's concern, and codesign signs with it regardless. Without
the identity in the keychain, `build.sh` falls back to ad-hoc signing and says so.

## Start it at login

`build.sh` installs `~/Library/LaunchAgents/com.adammackey.simplebattery.plist` and
bootstraps it, so the app comes back at every login. It appears in System Settings →
General → Login Items & Extensions under "Allow in the Background" and can be switched
off there.

To remove it for good:

```sh
launchctl bootout "gui/$UID/com.adammackey.simplebattery"
rm ~/Library/LaunchAgents/com.adammackey.simplebattery.plist
```

## Support

Simple Battery is free. If it saves you from a dead headset mid-call, you can
[buy me a coffee](https://buymeacoffee.com/adammackey).

## License

MIT. See [LICENSE](LICENSE).
