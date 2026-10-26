// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMem — free, open-source memory and disk cleaner for macOS.

import SwiftUI
import AppKit

private let catColors: [Cat: Color] = [.junk: .indigo, .dev: .teal, .dups: .purple, .apps: .orange, .installers: .pink, .large: .yellow]

private func pctColor(_ p: Int) -> Color { p < 60 ? .green : p < 85 ? .orange : .red }

private func icon(_ url: URL) -> NSImage { NSWorkspace.shared.icon(forFile: url.path) }

struct PanelView: View {
    @ObservedObject var m: Model
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: m.showSettings ? { m.showSettings = false } : close) {
                    Image(systemName: m.showSettings ? "chevron.left" : "xmark").font(.title3)
                }.buttonStyle(.plain)
                Spacer()
                Text(m.showSettings ? "Settings" : "OpenMem").font(.headline)
                Spacer()
                Button { m.showSettings.toggle() } label: { Image(systemName: "gearshape.fill").font(.title3) }
                    .buttonStyle(.plain).opacity(m.showSettings ? 0 : 1)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 10) {
                    if m.showSettings { SettingsView(m: m) } else {
                        MemoryCard(m: m)
                        DiskCard(m: m)
                    }
                    if !m.status.isEmpty {
                        Text(m.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            .defaultScrollAnchor(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.08))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct CardHeader: View {
    let title: String, pct: Int
    @Binding var open: Bool
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
            HStack {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption.bold()).frame(width: 12)
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Text("\(pct)%").font(.title.weight(.semibold)).foregroundStyle(pctColor(pct)).monospacedDigit()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct MemoryCard: View {
    @ObservedObject var m: Model
    var body: some View {
        Card {
            CardHeader(title: "Memory Usage", pct: m.mem.pct, open: $m.memOpen)
            ProgressView(value: min(m.mem.used, m.mem.total), total: max(m.mem.total, 1)).tint(.blue)
            if m.lastCleanAt > 0 {
                Label("\(fmtMem(m.lastCleanBytes)) cleaned at \(Date(timeIntervalSince1970: m.lastCleanAt).formatted(date: .omitted, time: .shortened))",
                      systemImage: "circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).labelStyle(DotLabel())
            }
            if m.memOpen {
                Divider()
                HStack {
                    Stat("Used", fmtMem(m.mem.used)); Stat("Cached", fmtMem(m.mem.cached))
                    Stat("Wired", fmtMem(m.mem.wired)); Stat("Compressed", fmtMem(m.mem.compressed))
                }
                Divider()
                Text("Heavy applications").font(.headline)
                ForEach(m.apps) { HeavyAppRow(a: $0) }
                if m.apps.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                Divider()
                HStack {
                    Text("Automatically free up").font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { m.autoFree }, set: { m.setAutoFree($0) })).toggleStyle(.switch).labelsHidden()
                }
            }
            Button { m.freeMemory() } label: {
                HStack { if m.freeing { ProgressView().controlSize(.small) }; Text(m.freeing ? "Freeing up…" : "Free up memory").bold() }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.freeing)
            .help("Shortcut: ⌃⌥⌘M, from any app")
        }
    }
}

struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 7)).foregroundStyle(.blue); configuration.title }
    }
}

struct Stat: View {
    let label: String, value: String
    init(_ l: String, _ v: String) { label = l; value = v }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HeavyAppRow: View {
    let a: HeavyApp
    @State private var hover = false
    var body: some View {
        HStack {
            Image(nsImage: a.app.icon ?? NSImage()).resizable().frame(width: 20, height: 20)
            Text(a.name).lineLimit(1)
            Spacer()
            if hover { Button("Quit") { a.app.terminate() }.controlSize(.small) }
            else { Text(fmtMem(a.bytes)).monospacedDigit() }
        }
        .frame(height: 22).contentShape(Rectangle()).onHover { hover = $0 }
    }
}

struct DiskCard: View {
    @ObservedObject var m: Model
    var d: DiskScan { m.disk }

    var body: some View {
        Card {
            CardHeader(title: "Disk Usage", pct: d.pct, open: $m.diskOpen)
            SegmentBar(parts: [(d.junkSize, catColors[.junk]!), (d.devSize, catColors[.dev]!), (d.dupSize, catColors[.dups]!),
                               (d.appsSize, catColors[.apps]!), (d.installersSize, catColors[.installers]!), (d.largeSize, catColors[.large]!)])
            if m.diskOpen {
                if !d.done {
                    HStack { ProgressView().controlSize(.small); Text("Scanning disk…").foregroundStyle(.secondary) }
                } else {
                    CategoryBox(m: m, cat: .junk, title: "Junk Files", size: d.junkSize) { JunkSection(m: m) }
                    CategoryBox(m: m, cat: .dev, title: "Developer Files", size: d.devSize) { DevSection(m: m) }
                    CategoryBox(m: m, cat: .dups, title: "Duplicate Files", size: d.dupSize) { DupSection(m: m) }
                    CategoryBox(m: m, cat: .apps, title: "Applications", size: d.appsSize) { AppsSection(m: m) }
                    CategoryBox(m: m, cat: .installers, title: "Installers", size: d.installersSize) {
                        ItemList(m: m, items: d.installers, what: "installers")
                    }
                    CategoryBox(m: m, cat: .large, title: "Large & Old Files", size: d.largeSize) {
                        ItemList(m: m, items: d.large, what: "large & old files")
                    }
                    HStack {
                        Text("\(fmtDisk(d.available)) available of \(fmtDisk(d.total))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(m.scanning ? "Scanning…" : "Rescan") { m.rescan() }.controlSize(.small).disabled(m.scanning)
                    }
                }
            }
        }
    }
}

struct SegmentBar: View {
    let parts: [(Int64, Color)]
    var body: some View {
        GeometryReader { g in
            let total = max(1, parts.reduce(0) { $0 + $1.0 })
            HStack(spacing: 3) {
                ForEach(parts.indices, id: \.self) { i in
                    Capsule().fill(parts[i].1).frame(width: max(4, g.size.width * CGFloat(parts[i].0) / CGFloat(total) - 3))
                }
            }
        }.frame(height: 8)
    }
}

struct CategoryBox<Content: View>: View {
    @ObservedObject var m: Model
    let cat: Cat, title: String, size: Int64
    @ViewBuilder let content: Content
    var open: Bool { m.expanded.contains(cat) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { m.toggle(cat) } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption.bold()).frame(width: 12)
                    Circle().fill(catColors[cat] ?? .gray).frame(width: 8, height: 8)
                    Text(title)
                    Spacer()
                    Text(fmtDisk(size)).monospacedDigit()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { Divider(); content }
        }
        .padding(open ? 10 : 4)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(open ? Color.accentColor.opacity(0.4) : .clear))
    }
}

struct JunkSection: View {
    @ObservedObject var m: Model
    var d: DiskScan { m.disk }
    var body: some View {
        Row("Caches", fmtDisk(d.cachesSize)) {
            Button("Clean") { m.trash(d.caches, what: "cache folders") }.controlSize(.small).disabled(d.caches.isEmpty)
        }
        Row("Downloads", fmtDisk(d.downloadsSize)) {
            Button(m.expanded.contains(.downloads) ? "Hide" : "Review") { m.toggle(.downloads) }.controlSize(.small)
        }
        if m.expanded.contains(.downloads) { ItemList(m: m, items: d.downloads, what: "downloads") }
        Row("Temporary files", fmtDisk(d.tempSize)) {
            Button("Clean") { m.trash(d.temp, what: "temporary items") }.controlSize(.small).disabled(d.temp.isEmpty)
                .help("Temp folder, /tmp and app logs not changed for a day. Files of running programs are skipped.")
        }
        Row("Uncleaned Trash", d.trash.map(fmtDisk) ?? "-") {
            if d.trash == nil {
                // macOS hides ~/.Trash from apps without Full Disk Access
                Button("Allow access") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }.controlSize(.small).help("Grant Full Disk Access to see the Trash size, then Rescan")
            } else {
                Button("Empty") { m.emptyTrash() }.controlSize(.small).disabled(d.trash == 0)
            }
        }
    }
}

struct Row<Action: View>: View {
    let label: String, value: String
    @ViewBuilder let action: Action
    init(_ l: String, _ v: String, @ViewBuilder action: () -> Action) { label = l; value = v; self.action = action() }
    var body: some View {
        HStack { Text(label); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary); action.frame(minWidth: 56) }
    }
}

struct ItemRow: View {
    @ObservedObject var m: Model
    let item: Item
    var tag = ""
    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { m.selected.contains(item.url) },
                                     set: { if $0 { m.selected.insert(item.url) } else { m.selected.remove(item.url) } }))
                .labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: icon(item.url)).resizable().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                let sub = [tag, item.note].filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty { Text(sub).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(fmtDisk(item.size)).font(.caption).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).help("Show in Finder")
        }
    }
}

struct ItemList: View {
    @ObservedObject var m: Model
    let items: [Item], what: String
    var chosen: [Item] { items.filter { m.selected.contains($0.url) } }
    var body: some View {
        if items.isEmpty { Text("Nothing found").font(.caption).foregroundStyle(.secondary) }
        ForEach(items.prefix(50)) { ItemRow(m: m, item: $0) }
        if items.count > 50 { Text("+ \(items.count - 50) more").font(.caption).foregroundStyle(.secondary) }
        if !items.isEmpty { TrashButton(count: chosen.count, size: chosen.reduce(0) { $0 + $1.size }) { m.trash(chosen, what: what) } }
    }
}

struct TrashButton: View {
    let count: Int, size: Int64, action: () -> Void
    var body: some View {
        Button(count == 0 ? "Select items to remove" : "Move \(count) to Trash (\(fmtDisk(size)))", action: action)
            .frame(maxWidth: .infinity).disabled(count == 0)
    }
}

struct DupSection: View {
    @ObservedObject var m: Model
    var all: [Item] { m.disk.dups.flatMap(\.files) }
    var body: some View {
        if m.disk.dups.isEmpty { Text("No duplicates found").font(.caption).foregroundStyle(.secondary) }
        else {
            Button("Select all copies (keep originals)") { m.selectAllCopies() }.controlSize(.small)
            ForEach(m.disk.dups.prefix(30)) { g in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(g.files.enumerated()), id: \.element.id) { i, f in
                        ItemRow(m: m, item: f, tag: i == 0 ? "Original" : "Copy · \(f.url.deletingLastPathComponent().lastPathComponent)")
                    }
                }
                Divider()
            }
            let chosen = all.filter { m.selected.contains($0.url) }
            TrashButton(count: chosen.count, size: chosen.reduce(0) { $0 + $1.size }) { m.trash(chosen, what: "duplicate files") }
        }
    }
}

struct DevSection: View {
    @ObservedObject var m: Model
    var body: some View {
        Text("Dependencies, build output and tool caches. Tools rebuild them or download them again.")
            .font(.caption).foregroundStyle(.secondary)
        if !m.disk.dev.isEmpty { Button("Select all") { m.selected.formUnion(m.disk.dev.map(\.url)) }.controlSize(.small) }
        ItemList(m: m, items: m.disk.dev, what: "developer files")
    }
}

struct AppsSection: View {
    @ObservedObject var m: Model
    var body: some View {
        if m.disk.appDataSize > 0 {
            Text("Includes \(fmtDisk(m.disk.appDataSize)) of app data, removed when you uninstall")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(m.disk.apps.prefix(60)) { a in AppRow(m: m, a: a) }
        if !m.disk.startup.isEmpty {
            Divider()
            HStack {
                Text("Start with your Mac").font(.headline)
                Spacer()
                Button("Login Items") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }.controlSize(.small).help("Turn these off in System Settings")
            }
            ForEach(m.disk.startup) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.label).lineLimit(1).truncationMode(.middle)
                        Text(s.missing ? "\(s.runs) · its app was removed" : s.runs).font(.caption2)
                            .foregroundStyle(s.missing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([s.url]) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).help("Show in Finder")
                }
            }
        }
    }
}

struct AppRow: View {
    @ObservedObject var m: Model
    let a: AppEntry
    @State private var hover = false
    var body: some View {
        HStack {
            Image(nsImage: icon(a.url)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(a.name).lineLimit(1)
                if !a.leftovers.isEmpty {
                    Text("App \(fmtDisk(a.size)) + data \(fmtDisk(a.total - a.size))").font(.caption2).foregroundStyle(.secondary)
                        .help(a.leftovers.map { $0.url.path.replacingOccurrences(of: home.path, with: "~") }.joined(separator: "\n"))
                }
            }
            Spacer()
            if hover { Button("Uninstall") { m.uninstall(a) }.controlSize(.small) }
            else { Text(fmtDisk(a.total)).font(.caption).monospacedDigit() }
        }
        .frame(height: 26).contentShape(Rectangle()).onHover { hover = $0 }
    }
}

struct SettingsView: View {
    @ObservedObject var m: Model
    var body: some View {
        Card {
            Toggle("Launch at login", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) })).toggleStyle(.switch)
            Picker("Menu bar shows", selection: $m.menuStyle) {
                Text("Memory %").tag(0); Text("Memory used").tag(1); Text("Icon only").tag(2)
            }
            Divider()
            Toggle("Automatically free up", isOn: Binding(get: { m.autoFree }, set: { m.setAutoFree($0) })).toggleStyle(.switch)
            Text("Free up when usage reaches \(Int(m.threshold))%").font(.caption)
            Slider(value: $m.threshold, in: 50...95, step: 5)
            Toggle("Notify when memory is high", isOn: $m.notifyHigh).toggleStyle(.switch)
            Toggle("Free up without password", isOn: Binding(get: { m.passwordless }, set: { m.setPasswordless($0) })).toggleStyle(.switch)
            Text("Asks for your password once, then allows only /usr/sbin/purge without a password.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Picker("Large file size", selection: $m.largeMB) {
                ForEach([50.0, 100, 250, 500, 1000], id: \.self) { Text("≥ \(Int($0)) MB").tag($0) }
            }
            Button("Rescan disk") { m.rescan() }.disabled(m.scanning)
            Divider()
            Button("Quit OpenMem") { NSApp.terminate(nil) }
        }
    }
}
