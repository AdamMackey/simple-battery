// Simple Battery: a menu bar battery icon showing the charge of the connected
// Bluetooth headset, with an optional percentage beside it. Nothing else: no
// window and no Dock icon. Click it for the percentage toggle and Quit.
//
// Where the number comes from: system_profiler and ioreg report no battery for
// these headsets, but bluetoothd keeps the level the headset sends over HFP,
// and private IOBluetoothDevice methods read it back. Private means an OS
// update can rename them, so every call goes through the @objc optional
// protocol below (a respondsToSelector check) and a missing value leaves the
// icon dimmed instead of crashing.
//
// Why a helper process: an IOBluetooth session held inside a long-running app
// goes bad in several ways — it blocks forever when the app lacks Bluetooth
// permission, and after the radio or a headset cycles it keeps reporting the
// device as connected while every battery selector returns zero, with no way to
// reset it. So this binary reads the level in "--read" mode and exits, and the
// menu bar app spawns that, with a timeout, rather than ever calling IOBluetooth
// itself. A fresh process cannot inherit a stale session.

import AppKit
import CoreBluetooth
import IOBluetooth

@objc protocol BatteryReading {
    @objc optional func batteryPercentCombined() -> UInt8
    @objc optional func batteryPercentSingle() -> UInt8
    @objc optional func batteryPercentLeft() -> UInt8
    @objc optional func batteryPercentRight() -> UInt8
}

/// The level this device reports, 1-100, or nil when it reports none.
/// Zero means "no report", not an empty battery.
func batteryPercent(of device: IOBluetoothDevice) -> Int? {
    let d = unsafeBitCast(device, to: BatteryReading.self)
    // Earbuds report each side separately; the lower side is the one that runs out.
    let sides = [d.batteryPercentLeft?(), d.batteryPercentRight?()]
        .compactMap { $0 }.map(Int.init).filter { $0 > 0 }
    if let lowest = sides.min() { return lowest }
    // Headphones report one level, in batteryPercentSingle on this Mac.
    return [d.batteryPercentCombined?(), d.batteryPercentSingle?()]
        .compactMap { $0 }.map(Int.init).first { $0 > 0 }
}

/// The battery glyph nearest to `level`. SF Symbols renamed these at some point
/// (battery.100 became battery.100percent), so try the current name and fall
/// back to the old one rather than ending up with no icon.
func batteryImage(for level: Int) -> (image: NSImage?, symbol: String) {
    let quarter: String
    switch level {
    case 88...: quarter = "100"
    case 63...: quarter = "75"
    case 38...: quarter = "50"
    case 13...: quarter = "25"
    default: quarter = "0"
    }
    for name in ["battery.\(quarter)percent", "battery.\(quarter)"] {
        if let image = NSImage(systemSymbolName: name,
                               accessibilityDescription: "headphone battery \(level) percent") {
            return (image, name)
        }
    }
    return (nil, "none")
}

struct Reading {
    let names: String
    let level: Int?
    var failed = false          // the helper never answered
}

// MARK: - Helper mode

/// Runs in the short-lived child process. Prints "level<tab>names" and exits.
func readAndPrint() -> Never {
    let connected = (IOBluetoothDevice.pairedDevices() ?? [])
        .compactMap { $0 as? IOBluetoothDevice }
        .filter { $0.isConnected() }
    let level = connected.compactMap(batteryPercent(of:)).min()
    let names = connected.map { $0.name ?? "?" }.joined(separator: ", ")
    print("\(level.map(String.init) ?? "")\t\(names)")
    exit(0)
}

// MARK: - The app

final class Menu: NSObject, NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let percentItem = NSMenuItem(title: "Show Percentage",
                                         action: #selector(togglePercent), keyEquivalent: "")
    private let reader = DispatchQueue(label: "com.adammackey.simplebattery.read", qos: .utility)
    private var reading = false
    private var central: CBCentralManager?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var userQuit = false
    private var poweringOff = false
    private var lastState = ""
    private let debug = ProcessInfo.processInfo.environment["SIMPLE_BATTERY_DEBUG"] != nil

    /// Survives quitting and relaunching. Flip it by hand with:
    /// defaults write com.adammackey.simplebattery showPercent -bool true
    private var showPercent: Bool {
        get { UserDefaults.standard.bool(forKey: "showPercent") }
        set { UserDefaults.standard.set(newValue, forKey: "showPercent") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS App Naps a menu bar app that looks idle, which stops the refresh
        // timer: the app then never notices a headset reconnecting. This opts out
        // for the life of the process.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Watching the headset battery level")

        item.button?.imagePosition = .imageLeading
        idle()

        // No ⌘Q on the Quit item: the app becomes active when its menu opens, so
        // a ⌘Q meant for another app can land here and quit this one.
        let menu = NSMenu()
        menu.delegate = self
        percentItem.target = self
        percentItem.state = showPercent ? .on : .off
        menu.addItem(percentItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu

        note("started pid \(ProcessInfo.processInfo.processIdentifier), "
             + "bluetooth authorization \(CBManager.authorization.rawValue)")

        // Only for noticing the radio coming back, and for recording the
        // permission state in the log. The helper does the actual reading.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])

        refresh()
        // 30s: the helper costs a few milliseconds, and without in-process
        // IOBluetooth notifications this poll is what spots a headset connecting.
        let ticker = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        ticker.tolerance = 5
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(recheckShortly), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(powerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        note("bluetooth state \(manager.state.rawValue), authorization \(CBManager.authorization.rawValue)")
        recheckShortly()
    }

    // MARK: - Reading

    private func refresh() {
        guard !reading else { return }
        reading = true
        reader.async { [weak self] in
            let reading = Menu.runHelper()
            DispatchQueue.main.async { self?.apply(reading) }
        }
    }

    /// Spawns this binary in --read mode. A read that hangs — no Bluetooth
    /// permission, a wedged daemon — is killed rather than allowed to freeze
    /// anything, because only the child is ever blocked.
    private static func runHelper() -> Reading {
        let task = Process()
        task.executableURL = Bundle.main.executableURL
        task.arguments = ["--read"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return Reading(names: "", level: nil, failed: true)
        }
        let killer = DispatchWorkItem {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()

        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return Reading(names: "", level: nil, failed: true)
        }
        let parts = text.components(separatedBy: "\t")
        return Reading(names: parts.count > 1 ? parts[1] : "", level: Int(parts[0]))
    }

    private func apply(_ result: Reading) {
        reading = false

        let state: String
        if let level = result.level {
            let (image, symbol) = batteryImage(for: level)
            item.button?.image = image
            item.button?.title = showPercent ? " \(level)%" : ""
            item.button?.appearsDisabled = false
            state = "connected=[\(result.names)] level=\(level) symbol=\(symbol) percent=\(showPercent)"
        } else {
            // Nothing connected, or connected with no level yet: sit there dimmed
            // rather than vanishing. A disappearing icon is indistinguishable from
            // a dead app, and clicking the app in Finder does nothing visible
            // because macOS just reactivates the copy already running.
            idle()
            state = result.failed
                ? "helper did not answer"
                : "connected=[\(result.names)] level=none"
        }
        item.isVisible = true

        log(state)
        if state != lastState {
            lastState = state
            note(state)
        }
    }

    private func idle() {
        item.button?.image = NSImage(systemSymbolName: "headphones",
                                     accessibilityDescription: "no headset battery")
        item.button?.title = ""
        item.button?.appearsDisabled = true
    }

    /// A headset sends its battery level a few seconds after the link is up, so
    /// look again rather than trusting one read after things change.
    @objc private func recheckShortly() {
        for delay in [1.0, 5.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    // MARK: - Menu

    /// Show a level the moment it lands rather than up to half a minute later.
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func togglePercent() {
        showPercent.toggle()
        percentItem.state = showPercent ? .on : .off
        refresh()
    }

    @objc private func quit() {
        userQuit = true
        NSApp.terminate(nil)
    }

    @objc private func powerOff() { poweringOff = true }

    /// The app had been exiting cleanly on its own, which is why the icon
    /// vanished and launchd left it down: a clean exit is not a failure.
    /// Anything that asks it to quit without going through the Quit item above
    /// now gets refused and written down.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if userQuit || poweringOff { return .terminateNow }
        note("refused a termination request; current event: \(NSApp.currentEvent?.description ?? "none")")
        return .terminateCancel
    }

    // MARK: - Logging

    private func log(_ line: String) {
        guard debug else { return }
        FileHandle.standardError.write("\(line)\n".data(using: .utf8)!)
    }

    /// A trail in ~/Library/Logs/SimpleBattery.log: starts, state changes and
    /// anything that tries to end the process. A few lines a day, so it can stay
    /// on — without it there was no way to tell why the icon went quiet.
    private func note(_ line: String) {
        log(line)
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SimpleBattery.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

if CommandLine.arguments.contains("--read") {
    readAndPrint()
}

let app = NSApplication.shared
let menu = Menu()
app.delegate = menu
app.setActivationPolicy(.accessory)
app.run()
