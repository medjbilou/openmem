// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMem — free, open-source memory and disk cleaner for macOS.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Kind: Int, CaseIterable {
    case apps, developer, video, audio, image, archive, cache, documents, other
    var name: String { ["Apps", "Developer", "Video", "Audio", "Images", "Archives & disk images", "Caches & logs", "Documents", "Other"][rawValue] }
    var color: Color { [Color.orange, .teal, .red, .pink, .green, .brown, .indigo, .blue, .gray][rawValue] }
}

final class Node: Identifiable {
    let name: String  // the full path for the root
    let isDir: Bool, rest: Bool  // rest: the small files of a folder, shown as one block
    var size: Int64 = 0, files = 0, folders = 0
    var kind: Kind
    var modified: Date?, created: Date?
    var children: [Node] = []  // biggest first
    weak var parent: Node?

    init(_ name: String, isDir: Bool, kind: Kind, rest: Bool = false) { self.name = name; self.isDir = isDir; self.kind = kind; self.rest = rest }
    var url: URL { parent.map { $0.url.appending(path: name) } ?? URL(fileURLWithPath: name) }
    var title: String { parent == nil ? fm.displayName(atPath: name) : name }
}

// shortcut: files under 1 MB are summed into one "Small files" block per folder to keep memory low on
// millions of files; keep every file if a view ever needs to list them.
private let minFileNode: Int64 = 1 << 20
private let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isVolumeKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .creationDateKey]
private let devDirs: Set = ["node_modules", ".git", "DerivedData", ".gradle", ".npm", ".cargo", ".m2", ".pnpm-store",
                            ".venv", "venv", "Pods", ".build", ".next"]

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add(_ k: Int) { lock.withLock { n += k } }
    var value: Int { lock.withLock { n } }
}

// Bytes per kind, and the kind of each file extension already seen (UTType lookups are slow).
private struct Tally {
    var kinds = [Int64](repeating: 0, count: Kind.allCases.count)
    var types: [String: Kind] = [:]

    mutating func kind(_ ext: String) -> Kind {
        if let k = types[ext] { return k }
        let t = UTType(filenameExtension: ext.lowercased())
        func is_(_ u: UTType) -> Bool { t?.conforms(to: u) == true }
        // Source code before text: source code is a kind of text.
        let k: Kind = is_(.movie) ? .video : is_(.audio) ? .audio : is_(.image) ? .image
            : is_(.archive) || is_(.diskImage) ? .archive : is_(.sourceCode) ? .developer
            : is_(.text) || is_(.pdf) || is_(.presentation) || is_(.spreadsheet) ? .documents : .other
        types[ext] = k
        return k
    }
}

// A folder's kind applies to everything inside it: an app bundle is Apps, node_modules is Developer.
private func folderKind(_ u: URL, _ v: URLResourceValues) -> Kind? {
    if v.isPackage == true, u.pathExtension == "app" { return .apps }
    if devDirs.contains(u.lastPathComponent) || u.path == home.appending(path: "Library/Developer").path { return .developer }
    if u.path == cachesDir.path || u.path == home.appending(path: "Library/Logs").path { return .cache }
    return nil
}

// Hidden files are included. Symlinks are not followed and other disks mounted inside are skipped.
// The root's top folders are walked in parallel.
private func walk(_ url: URL, _ name: String, _ ctx: Kind?, keep: Bool, parallel: Bool, _ t: inout Tally, _ c: Counter) -> Node {
    let node = Node(name, isDir: true, kind: ctx ?? .other)
    var dirs: [(url: URL, pkg: Bool, modified: Date?, created: Date?, kind: Kind?)] = []
    let rest = Node("Small files", isDir: false, kind: .other, rest: true)
    // Background threads have no autorelease pool of their own: without this, every URL ever listed stays in memory.
    autoreleasepool {
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        c.add(items.count)
        for u in items {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if v.isVolume != true { dirs.append((u, v.isPackage == true, v.contentModificationDate, v.creationDate, ctx ?? folderKind(u, v))) }
                continue
            }
            let size = Int64(v.totalFileAllocatedSize ?? 0), k = ctx ?? t.kind(u.pathExtension)
            t.kinds[k.rawValue] += size
            node.size += size
            node.files += 1
            if keep && size >= minFileNode {
                let f = Node(u.lastPathComponent, isDir: false, kind: k)
                f.size = size; f.files = 1; f.modified = v.contentModificationDate; f.created = v.creationDate
                node.children.append(f)
            } else { rest.size += size; rest.files += 1 }
        }
    }
    var subs = [Node?](repeating: nil, count: dirs.count)
    if parallel {
        final class Box: @unchecked Sendable { let lock = NSLock(); var nodes: [Node?] = []; var tallies: [Tally] = [] }
        let box = Box(), list = dirs
        box.nodes = subs
        DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
            var sub = Tally()
            let d = list[i]
            let n = walk(d.url, d.url.lastPathComponent, d.kind, keep: keep && !d.pkg, parallel: false, &sub, c)
            box.lock.withLock { box.nodes[i] = n; box.tallies.append(sub) }
        }
        subs = box.nodes
        for s in box.tallies { for i in t.kinds.indices { t.kinds[i] += s.kinds[i] } }
    } else {
        for (i, d) in dirs.enumerated() { subs[i] = walk(d.url, d.url.lastPathComponent, d.kind, keep: keep && !d.pkg, parallel: false, &t, c) }
    }
    for (i, sub) in subs.enumerated() {
        guard let sub else { continue }
        sub.modified = dirs[i].modified
        sub.created = dirs[i].created
        node.size += sub.size; node.files += sub.files; node.folders += sub.folders + 1
        if keep { node.children.append(sub) }
    }
    if keep && rest.size > 0 { node.children.append(rest) }
    for ch in node.children { ch.parent = node }
    node.children.sort { $0.size > $1.size }
    return node
}

// Squarified treemap: biggest first, rows of rectangles kept as close to square as possible.
func squarify(_ sizes: [Double], in r: CGRect) -> [CGRect] {
    let total = sizes.reduce(0, +)
    guard total > 0, r.width > 0, r.height > 0 else { return sizes.map { _ in .zero } }
    let areas = sizes.map { $0 * r.width * r.height / total }
    var out: [CGRect] = [], rect = r, i = 0
    while i < areas.count {
        let side = Double(min(rect.width, rect.height))
        func worst(_ row: ArraySlice<Double>) -> Double {
            let s = row.reduce(0, +), hi = row.max() ?? 0, lo = row.min() ?? 0
            return max(side * side * hi / (s * s), s * s / (side * side * max(lo, .leastNonzeroMagnitude)))
        }
        var j = i + 1
        while j < areas.count, worst(areas[i...j]) <= worst(areas[i..<j]) { j += 1 }
        let thick = areas[i..<j].reduce(0, +) / max(side, .leastNonzeroMagnitude)
        let wide = rect.width >= rect.height
        var off = 0.0
        for a in areas[i..<j] {
            let len = a / max(thick, .leastNonzeroMagnitude)
            out.append(wide ? CGRect(x: rect.minX, y: rect.minY + off, width: thick, height: len)
                            : CGRect(x: rect.minX + off, y: rect.minY, width: len, height: thick))
            off += len
        }
        rect = wide ? CGRect(x: rect.minX + thick, y: rect.minY, width: max(0, rect.width - thick), height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + thick, width: rect.width, height: max(0, rect.height - thick))
        i = j
    }
    return out
}

@MainActor final class SpaceModel: ObservableObject {
    @Published var root: Node?
    @Published var current: Node?
    @Published var selected: Node?
    @Published var kinds = [Int64](repeating: 0, count: Kind.allCases.count)
    @Published var scanning = false
    @Published var scanned = 0
    @Published var showList = false
    @Published var fullAccess = true
    @Published var status = ""
    var folder = home
    var onTrash: (() -> Void)?

    func scan(_ url: URL) {
        guard !scanning else { return }
        folder = url
        scanning = true
        scanned = 0
        status = ""
        let c = Counter()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in Task { @MainActor in self?.scanned = c.value } }
        Task.detached(priority: .utility) {
            var t = Tally()
            let root = walk(url, url.path, nil, keep: true, parallel: true, &t, c)
            // Without Full Disk Access macOS hides the Trash, Mail and other folders: totals are then incomplete.
            let full = (try? fm.contentsOfDirectory(atPath: trashDir.path)) != nil
            let kinds = t.kinds
            await MainActor.run {
                timer.invalidate()
                self.root = root
                self.current = root
                self.selected = nil
                self.kinds = kinds
                self.fullAccess = full
                self.scanning = false
            }
        }
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = folder
        p.prompt = "Scan"
        p.message = "Choose a folder or a drive to scan"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { scan(u) }
    }

    func open(_ n: Node) {
        if n.isDir && !n.children.isEmpty { current = n; selected = nil } else { selected = n }
    }

    func up() { if let p = current?.parent { current = p; selected = nil } }

    func canTrash(_ n: Node) -> Bool { !scanning && !n.rest && n.parent != nil && Safety.canTrash(n.url) }

    func trash(_ n: Node) {
        guard canTrash(n), let p = n.parent,
              confirm("Move \(n.name) (\(fmtDisk(n.size))) to the Trash?", "You can restore it from the Trash until you empty it.") else { return }
        guard moveToTrash([Item(url: n.url, size: n.size)]).moved == 1 else { status = "Could not move \(n.name) to the Trash"; return }
        p.children.removeAll { $0 === n }
        // shortcut: kind totals are not split per folder, so they stay as scanned until the next scan.
        for a in sequence(first: p, next: { $0.parent }) {
            a.size -= n.size; a.files -= n.files; a.folders -= n.folders + (n.isDir ? 1 : 0)
        }
        selected = nil
        status = "Moved \(n.name) (\(fmtDisk(n.size))) to the Trash. Empty the Trash to free the space."
        objectWillChange.send()
        onTrash?()
    }
}

struct SpaceView: View {
    @ObservedObject var s: SpaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { s.up() } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command).disabled(s.current?.parent == nil).help("Enclosing folder (⌘↑)")
                Button { s.choose() } label: { Label("Choose Folder…", systemImage: "folder") }.disabled(s.scanning)
                Button { s.scan(s.folder) } label: { Label("Rescan", systemImage: "arrow.clockwise") }.disabled(s.scanning)
                Spacer()
                Picker("View", selection: $s.showList) {
                    Image(systemName: "square.grid.2x2").tag(false).help("Treemap")
                    Image(systemName: "list.bullet").tag(true).help("Largest first")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 90)
            }.padding(10)
            if let cur = s.current {
                KindBar(kinds: s.kinds).padding(.horizontal, 10)
                Breadcrumbs(s: s, node: cur).padding(10)
                HStack(alignment: .top, spacing: 10) {
                    Group { if s.showList { LargestList(s: s, node: cur) } else { Treemap(s: s, node: cur) } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Inspector(s: s, n: s.selected ?? cur).frame(width: 250)
                }.padding([.horizontal, .bottom], 10)
            } else {
                Spacer()
                ProgressView("Scanning… \(s.scanned.formatted()) items").frame(maxWidth: .infinity)
                Spacer()
            }
            Divider()
            HStack {
                if s.scanning { ProgressView().controlSize(.small); Text("Scanning… \(s.scanned.formatted()) items") }
                else if let r = s.root { Text("\(fmtDisk(r.size)) in \(r.files.formatted()) files and \(r.folders.formatted()) folders") }
                if !s.status.isEmpty { Text(s.status) }
                Spacer()
                if !s.fullAccess {
                    Text("Some folders are hidden from OpenMem, so sizes may be incomplete.")
                    Button("Allow access") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }.controlSize(.small).help("Grant Full Disk Access, then Rescan")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

struct KindBar: View {
    let kinds: [Int64]
    var parts: [(Kind, Int64)] { Kind.allCases.map { ($0, kinds[$0.rawValue]) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SegmentBar(parts: parts.map { ($0.1, $0.0.color) })
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 6) {
                        Circle().fill(p.0.color).frame(width: 8, height: 8)
                        Text(p.0.name)
                        Text(fmtDisk(p.1)).monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
        }
    }
}

struct Breadcrumbs: View {
    @ObservedObject var s: SpaceModel
    let node: Node
    var body: some View {
        let chain = Array(sequence(first: node, next: { $0.parent })).reversed()
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(chain) { n in
                        if n.parent != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                        Button(n.title) { s.current = n; s.selected = nil }.buttonStyle(.plain).fontWeight(n === node ? .semibold : .regular)
                    }
                }
            }
            Text(fmtDisk(node.size)).monospacedDigit().fontWeight(.semibold)
        }
    }
}

struct Treemap: View {
    @ObservedObject var s: SpaceModel
    let node: Node
    var body: some View {
        GeometryReader { g in
            let items = Array(node.children.filter { $0.size > 0 }.prefix(150))
            let rects = squarify(items.map { Double($0.size) }, in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(items, rects)), id: \.0.id) { n, r in
                    Tile(n: n, selected: s.selected === n)
                        .frame(width: max(0, r.width - 2), height: max(0, r.height - 2))
                        .offset(x: r.minX + 1, y: r.minY + 1)
                        .onTapGesture { s.open(n) }
                        .help("\(n.name): \(fmtDisk(n.size))")
                }
            }
        }
    }
}

struct Tile: View {
    let n: Node, selected: Bool
    var body: some View {
        let c = n.rest ? Color.gray : n.isDir && n.kind == .other ? Color.accentColor : n.kind.color
        RoundedRectangle(cornerRadius: 4).fill(c.opacity(n.isDir ? 0.6 : 0.85))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.primary : .clear, lineWidth: 2))
            .overlay(alignment: .topLeading) {
                GeometryReader { g in
                    if g.size.width > 50 && g.size.height > 30 {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(n.name).font(.caption.weight(.medium)).lineLimit(1)
                            Text(fmtDisk(n.size)).font(.caption2).opacity(0.85)
                        }.foregroundStyle(.white).padding(4)
                    }
                }
            }
            .contentShape(Rectangle())
    }
}

struct LargestList: View {
    @ObservedObject var s: SpaceModel
    let node: Node
    var body: some View {
        List(Array(node.children.prefix(300))) { n in
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: n.rest ? "/var/empty" : n.url.path)).resizable().frame(width: 18, height: 18)
                Text(n.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                ProgressView(value: Double(n.size), total: Double(max(node.size, 1))).frame(width: 120)
                Text(fmtDisk(n.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { s.open(n) }
            .listRowBackground(s.selected === n ? Color.accentColor.opacity(0.2) : nil)
        }
    }
}

struct Inspector: View {
    @ObservedObject var s: SpaceModel
    let n: Node
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !n.rest { Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path)).resizable().frame(width: 48, height: 48) }
                Text(n.title).font(.headline).lineLimit(2)
                if !n.rest {
                    Text(n.url.path.replacingOccurrences(of: home.path, with: "~")).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { Text("Size on disk").foregroundStyle(.secondary); Text(fmtDisk(n.size)).monospacedDigit() }
                    if n.isDir || n.rest { GridRow { Text("Files").foregroundStyle(.secondary); Text(n.files.formatted()) } }
                    if n.isDir { GridRow { Text("Folders").foregroundStyle(.secondary); Text(n.folders.formatted()) } }
                    if let p = n.parent, p.size > 0 {
                        GridRow { Text("Share of folder").foregroundStyle(.secondary); Text((Double(n.size) / Double(p.size)).formatted(.percent.precision(.fractionLength(1)))) }
                    }
                    if let d = n.created { GridRow { Text("Created").foregroundStyle(.secondary); Text(d.formatted(date: .abbreviated, time: .omitted)) } }
                    if let d = n.modified { GridRow { Text("Modified").foregroundStyle(.secondary); Text(d.formatted(date: .abbreviated, time: .omitted)) } }
                }.font(.caption)
                if n.isDir && !n.children.isEmpty {
                    Divider()
                    Text("Largest inside").font(.caption.weight(.semibold))
                    ForEach(n.children.prefix(5)) { c in
                        Button { s.open(c) } label: {
                            HStack { Text(c.name).lineLimit(1).truncationMode(.middle); Spacer(); Text(fmtDisk(c.size)).monospacedDigit() }
                        }.buttonStyle(.plain).font(.caption)
                    }
                }
                if !n.rest {
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
                    Button("Move to Trash") { s.trash(n) }.disabled(!s.canTrash(n))
                        .help(s.canTrash(n) ? "" : "OpenMem only removes items inside your user folders, caches, temporary folders and apps")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
