// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMem — free, open-source memory and disk cleaner for macOS.

import Carbon
import SwiftUI
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let model = Model()
    let space = SpaceModel()
    let popover = NSPopover()
    var item: NSStatusItem!
    var spaceWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Memory usage")
            b.imagePosition = .imageLeading
            b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            b.target = self
            b.action = #selector(toggle)
        }
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(m: model) { [weak self] in self?.popover.performClose(nil) })
        host.sizingOptions = []  // SwiftUI auto-sizing makes NSPopover grow upward off-screen
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 360, height: 760)
        model.onTick = { [weak self] in self?.updateTitle() }
        model.openSpace = { [weak self] in self?.openSpace() }
        space.onTrash = { [weak self] in self?.model.rescan() }
        model.start()
        updateTitle()
        if CommandLine.arguments.contains("--open") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() } }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        registerHotKey()
    }

    // ⌃⌥⌘M frees memory from anywhere. Carbon hot keys need no Accessibility permission.
    func registerHotKey() {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey | controlKey),
                            EventHotKeyID(signature: 0x4F4D454D, id: 1), GetApplicationEventTarget(), 0, &ref)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            let d = Unmanaged<AppDelegate>.fromOpaque(me!).takeUnretainedValue()
            MainActor.assumeIsolated { d.model.freeMemory() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func updateTitle() {
        guard let b = item.button else { return }
        let m = model.mem
        let title = switch model.menuStyle {
        case 1: " " + fmtMem(m.used)
        case 2: ""
        default: " \(m.pct)%"
        }
        // Warning/danger colors: orange 10 points below the threshold, red at it.
        let pct = Double(m.pct)
        let color: NSColor? = pct >= model.threshold ? .systemRed : pct >= model.threshold - 10 ? .systemOrange : nil
        b.contentTintColor = color
        if let color, let font = b.font {
            b.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        } else {
            b.title = title
        }
        b.toolTip = "Memory: \(fmtMem(m.used)) of \(fmtMem(m.total)) used"
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        model.panelOpened()
        popover.contentSize = NSSize(width: 360, height: min(760, (b.window?.screen?.visibleFrame.height ?? 800) - 20))
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ n: Notification) { model.panelVisible = false }

    func openSpace() {
        if spaceWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SpaceView(s: space)))
            w.title = "Disk Space"
            w.setContentSize(NSSize(width: 1000, height: 660))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            spaceWindow = w
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        spaceWindow?.makeKeyAndOrderFront(nil)
        if space.root == nil { space.scan(space.folder) }
    }

    // A home folder's tree holds about 150 MB: a memory app frees it when the window closes.
    func windowWillClose(_ n: Notification) { space.root = nil; space.current = nil; space.selected = nil }

    // Accessory apps are always "foreground", so banners must be allowed explicitly.
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
