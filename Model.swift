// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMem — free, open-source memory and disk cleaner for macOS.

import AppKit
import ServiceManagement
import UserNotifications

private let ud = UserDefaults.standard

enum Cat: String { case junk, downloads, dups, apps, large }

@MainActor final class Model: ObservableObject {
    @Published var mem = readMem()
    @Published var apps: [HeavyApp] = []
    @Published var freeing = false
    @Published var disk = DiskScan()
    @Published var scanning = false
    @Published var status = ""
    @Published var showSettings = false
    @Published var memOpen = true
    @Published var diskOpen = true
    @Published var expanded: Set<Cat> = [.junk]
    @Published var selected: Set<URL> = []
    @Published var passwordless = Purge.passwordless
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published var autoFree = ud.bool(forKey: "autoFree") { didSet { ud.set(autoFree, forKey: "autoFree") } }
    @Published var threshold = ud.object(forKey: "threshold") as? Double ?? 80 { didSet { ud.set(threshold, forKey: "threshold") } }
    @Published var notifyHigh = ud.object(forKey: "notifyHigh") as? Bool ?? true { didSet { ud.set(notifyHigh, forKey: "notifyHigh") } }
    @Published var menuStyle = ud.integer(forKey: "menuStyle") { didSet { ud.set(menuStyle, forKey: "menuStyle"); onTick?() } }
    @Published var largeMB = ud.object(forKey: "largeMB") as? Double ?? 100 { didSet { ud.set(largeMB, forKey: "largeMB") } }
    @Published var lastCleanBytes = ud.double(forKey: "lastCleanBytes") { didSet { ud.set(lastCleanBytes, forKey: "lastCleanBytes") } }
    @Published var lastCleanAt = ud.double(forKey: "lastCleanAt") { didSet { ud.set(lastCleanAt, forKey: "lastCleanAt") } }

    var onTick: (() -> Void)?
    var panelVisible = false { didSet { if panelVisible { tick() } } }
    private var lastAuto = Date.distantPast
    private var wasHigh = false
    private var lastScan = Date.distantPast
    private var timer: Timer?

    func start() {
        // Menu bar only needs one host_statistics call every 3 s; heavy apps only while the panel is open.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        rescan()
    }

    func tick() {
        mem = readMem()
        if panelVisible { apps = heavyApps() }
        onTick?()
        let high = Double(mem.pct) >= threshold
        if autoFree, high, passwordless, !freeing, Date().timeIntervalSince(lastAuto) > 120 {
            lastAuto = Date()
            freeMemory(auto: true)
        } else if notifyHigh, high, !wasHigh, !autoFree {
            notify("Memory usage is \(mem.pct)%", "Click the menu bar icon to free up memory.")
        }
        if high { wasHigh = true } else if Double(mem.pct) < threshold - 5 { wasHigh = false }
    }

    func panelOpened() {
        panelVisible = true
        if Date().timeIntervalSince(lastScan) > 600 { rescan() }
    }

    func freeMemory(auto: Bool = false) {
        guard !freeing else { return }
        freeing = true
        let before = readMem().free
        Task.detached {
            let ok = Purge.run(dropFileCache: !auto)
            await MainActor.run {
                self.freeing = false
                self.passwordless = Purge.passwordless
                guard ok else { self.status = "Free up cancelled"; return }
                let freed = max(0, readMem().free - before)
                self.lastCleanBytes = freed
                self.lastCleanAt = Date().timeIntervalSince1970
                self.tick()
                // Panel closed means auto or hot key: no UI shows the result, so notify.
                if auto || !self.panelVisible { notify("Memory freed", "\(fmtMem(freed)) cleaned" + (auto ? " automatically" : "")) }
            }
        }
    }

    func setAutoFree(_ on: Bool) {
        guard on, !passwordless else { autoFree = on; return }
        Task.detached {
            let ok = Purge.enablePasswordless()
            await MainActor.run { self.passwordless = Purge.passwordless; self.autoFree = ok }
        }
    }

    func setPasswordless(_ on: Bool) {
        Task.detached {
            _ = on ? Purge.enablePasswordless() : Purge.disablePasswordless()
            await MainActor.run {
                self.passwordless = Purge.passwordless
                if !self.passwordless { self.autoFree = false }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
        catch { status = "Launch at login failed: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        lastScan = Date()
        if !disk.done { disk = volumeStats() }  // show disk % instantly, before the slow walk
        let mb = largeMB
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        Task.detached(priority: .utility) {
            let s = scanDisk(largeMB: mb, runningIDs: running)
            await MainActor.run {
                self.disk = s
                self.scanning = false
                self.selected.formIntersection(Set(s.downloads.map(\.url) + s.large.map(\.url) + s.dups.flatMap { $0.files.map(\.url) }))
            }
        }
    }

    // MARK: cleanup actions — all go through moveToTrash, which enforces Safety.

    func trash(_ items: [Item], what: String) {
        guard !items.isEmpty else { return }
        let total = items.reduce(0) { $0 + $1.size }
        guard confirm("Move \(items.count) \(what) (\(fmtDisk(total))) to the Trash?",
                      "You can restore them from the Trash until you empty it.") else { return }
        let r = moveToTrash(items)
        selected.subtract(items.map(\.url))
        status = "Moved \(r.moved) items (\(fmtDisk(r.bytes))) to Trash"
            + (r.failed.isEmpty ? "" : ". Skipped \(r.failed.count): \(r.failed.prefix(3).joined(separator: ", "))")
        rescan()
    }

    func trashSelected(from items: [Item], what: String) { trash(items.filter { selected.contains($0.url) }, what: what) }

    func uninstall(_ a: AppEntry) {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == a.bundleID }) {
            status = "Quit \(a.name) first"
            return
        }
        trash([Item(url: a.url, size: a.size)] + a.leftovers, what: "files of \(a.name)")
    }

    func emptyTrash() {
        guard confirm("Empty the Trash?", "This permanently deletes the items in the Trash. You cannot undo this.") else { return }
        let ok = sh("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
        status = ok ? "Trash emptied" : "Could not empty the Trash"
        rescan()
    }

    func selectAllCopies() {
        for g in disk.dups { for f in g.files.dropFirst() { selected.insert(f.url) } }
    }

    func toggle(_ c: Cat) { if expanded.contains(c) { expanded.remove(c) } else { expanded.insert(c) } }
}

@MainActor func confirm(_ title: String, _ text: String) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.addButton(withTitle: "Continue")
    a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    return a.runModal() == .alertFirstButtonReturn
}

func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}
