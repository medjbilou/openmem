// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMem — free, open-source memory and disk cleaner for macOS.

import AppKit
import CryptoKit

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let cachesDir = home.appending(path: "Library/Caches")
let downloadsDir = home.appending(path: "Downloads")
let trashDir = home.appending(path: ".Trash")
let userRoots = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home.appending(path: $0) }
let appRoots = [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")]
let ownID = Bundle.main.bundleIdentifier ?? "io.github.medjbilou.openmem"
// Like Windows %TEMP%: the per-user temp folder, /tmp, and app logs. Not caches.
let tempDirs = [URL(fileURLWithPath: NSTemporaryDirectory()), URL(fileURLWithPath: "/private/tmp"), home.appending(path: "Library/Logs")]

// Exact bundle-id leftovers. Exact app-name folders are added in appLeftovers.
let leftoverPatterns: [(dir: String, suffix: String)] = [
    ("Library/Application Support", ""), ("Library/Caches", ""), ("Library/Containers", ""),
    ("Library/HTTPStorages", ""), ("Library/WebKit", ""), ("Library/Logs", ""),
    ("Library/Saved Application State", ".savedState"), ("Library/Preferences", ".plist"),
]

struct Item: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var date: Date? = nil
    var note = ""
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct DupGroup: Identifiable {
    let id: String
    let files: [Item]  // oldest first: files[0] is the original
    var waste: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

struct AppEntry: Identifiable {
    let url: URL, name: String, bundleID: String, size: Int64, leftovers: [Item]
    var id: URL { url }
    var total: Int64 { size + leftovers.reduce(0) { $0 + $1.size } }
}

struct DiskScan {
    var total: Int64 = 0, available: Int64 = 0
    var caches: [Item] = [], downloads: [Item] = [], temp: [Item] = [], trash: Int64? = nil
    var dups: [DupGroup] = [], apps: [AppEntry] = [], large: [Item] = []
    var done = false

    var pct: Int { total > 0 ? Int(Double(total - available) / Double(total) * 100) : 0 }
    var cachesSize: Int64 { caches.reduce(0) { $0 + $1.size } }
    var downloadsSize: Int64 { downloads.reduce(0) { $0 + $1.size } }
    var tempSize: Int64 { temp.reduce(0) { $0 + $1.size } }
    var junkSize: Int64 { cachesSize + downloadsSize + tempSize + (trash ?? 0) }
    var dupSize: Int64 { dups.reduce(0) { $0 + $1.waste } }
    var appsSize: Int64 { apps.reduce(0) { $0 + $1.total } }  // apps plus their data, same as each row
    var appDataSize: Int64 { apps.reduce(0) { $0 + $1.total - $1.size } }
    var largeSize: Int64 { large.reduce(0) { $0 + $1.size } }
}

// Trust boundary: nothing leaves these folders, roots themselves are never touched,
// and everything goes to the Trash (recoverable). Only "Empty Trash" is permanent.
enum Safety {
    static let roots = ([cachesDir] + userRoots + appRoots + tempDirs + leftoverPatterns.map { home.appending(path: $0.dir) })
        .map { $0.resolvingSymlinksInPath().path }

    static func canTrash(_ url: URL) -> Bool {
        // Resolve the parent only, so a symlink item trashes the link, never its target.
        let p = url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent).path
        guard url.lastPathComponent != "..", roots.contains(where: { p.hasPrefix($0 + "/") }) else { return false }
        if appRoots.contains(where: { p.hasPrefix($0.path + "/") }) {
            guard url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier, !id.hasPrefix("com.apple."), id != ownID else { return false }
        }
        return true
    }
}

struct TrashResult { var moved = 0; var bytes: Int64 = 0; var failed: [String] = [] }

func moveToTrash(_ items: [Item]) -> TrashResult {
    var r = TrashResult()
    for i in items {
        guard Safety.canTrash(i.url) else { r.failed.append(i.name); continue }
        let ok = i.url.pathExtension == "app" ? finderTrash(i.url) : (try? fm.trashItem(at: i.url, resultingItemURL: nil)) != nil
        if ok { r.moved += 1; r.bytes += i.size } else { r.failed.append(i.name) }
    }
    return r
}

// Apps go through Finder: it asks for the admin password when root owns the app (pkg installers),
// and macOS lets Finder delete apps, while App Management blocks other apps from doing it.
// The path is passed as an argument, never spliced into the script.
func finderTrash(_ url: URL) -> Bool {
    sh("/usr/bin/osascript", ["-e", "on run a", "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of a) as alias)",
                              "-e", "end run", url.path])
}

private let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]

func allocSize(_ url: URL) -> Int64 {
    let v = try? url.resourceValues(forKeys: sizeKeys)
    if v?.isRegularFile == true { return Int64(v?.totalFileAllocatedSize ?? 0) }
    guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(sizeKeys), options: [], errorHandler: { _, _ in true }) else { return 0 }
    var t: Int64 = 0
    for case let f as URL in e { t += Int64((try? f.resourceValues(forKeys: sizeKeys))?.totalFileAllocatedSize ?? 0) }
    return t
}

private func children(_ dir: URL) -> [URL] {
    (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
}

private func digest(_ url: URL, limit: Int? = nil) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while let c = try? h.read(upToCount: limit ?? 1 << 20), !c.isEmpty {
        hasher.update(data: c)
        if limit != nil { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// Git repos and dependency folders hold project files: never offered for cleanup.
private func isProtectedDir(_ u: URL) -> Bool {
    ["node_modules", ".venv", "venv", "Pods"].contains(u.lastPathComponent) || fm.fileExists(atPath: u.appending(path: ".git").path)
}

func volumeStats() -> DiskScan {
    var s = DiskScan()
    // A new URL each time: URL caches resource values, so reusing `home` froze the free space at its first reading.
    if let v = try? URL(fileURLWithPath: home.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
        s.total = Int64(v.volumeTotalCapacity ?? 0)
        s.available = v.volumeAvailableCapacityForImportantUsage ?? 0
    }
    return s
}

func scanDisk(largeMB: Double, runningIDs: Set<String>) -> DiskScan {
    var s = volumeStats()

    // Caches: skip Apple system caches and caches of apps that are running right now.
    s.caches = children(cachesDir)
        .filter { n in let id = n.lastPathComponent; return !id.hasPrefix("com.apple.") && id != ownID && !runningIDs.contains(id) }
        .map { Item(url: $0, size: allocSize($0)) }.filter { $0.size > 0 }.sorted { $0.size > $1.size }

    s.downloads = children(downloadsDir).map {
        Item(url: $0, size: allocSize($0), date: (try? $0.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate)
    }.sorted { $0.size > $1.size }

    s.temp = tempDirs.flatMap(tempItems).sorted { $0.size > $1.size }

    // ~/.Trash needs Full Disk Access; without it we show "-" like the original.
    if (try? fm.contentsOfDirectory(atPath: trashDir.path)) != nil { s.trash = allocSize(trashDir) }

    // One walk feeds both duplicates and large & old files.
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                  .contentAccessDateKey, .contentModificationDateKey, .creationDateKey,
                                  .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    let mb: Int64 = 1 << 20
    let oneYearAgo = Date().addingTimeInterval(-365 * 86_400)
    var bySize: [Int64: [Item]] = [:]
    for root in userRoots {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true { if isProtectedDir(u) { e.skipDescendants() }; continue }
            guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize.map(Int64.init), size >= mb else { continue }
            // Skip iCloud placeholders: reading them would trigger a download.
            if v.isUbiquitousItem == true, v.ubiquitousItemDownloadingStatus != .current { continue }
            bySize[size, default: []].append(Item(url: u, size: size, date: v.creationDate))
            let last = max(v.contentAccessDate ?? .distantPast, v.contentModificationDate ?? .distantPast)
            let old = size >= 10 * mb && last < oneYearAgo
            if Double(size) >= largeMB * Double(mb) || old {
                s.large.append(Item(url: u, size: size, date: last, note: old ? "Not opened for over a year" : ""))
            }
        }
    }
    s.large = Array(s.large.sorted { $0.size > $1.size }.prefix(200))

    // Duplicates: same size, then same first 64 KB, then same full SHA-256.
    for group in bySize.values where group.count > 1 {
        for (_, sameHead) in Dictionary(grouping: group, by: { digest($0.url, limit: 65_536) ?? UUID().uuidString }) where sameHead.count > 1 {
            for (hash, same) in Dictionary(grouping: sameHead, by: { digest($0.url) ?? UUID().uuidString }) where same.count > 1 {
                s.dups.append(DupGroup(id: hash, files: same.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }))
            }
        }
    }
    s.dups = Array(s.dups.sorted { $0.waste > $1.waste }.prefix(200))

    for root in appRoots {
        // Top level plus one folder deep, for vendor folders such as "/Applications/Python 3.12".
        let top = children(root)
        let bundles = top + top.filter { $0.pathExtension != "app" }.flatMap(children)
        for u in bundles where u.pathExtension == "app" {
            guard let id = Bundle(url: u)?.bundleIdentifier, !id.hasPrefix("com.apple."), id != ownID else { continue }
            let leftovers = appLeftovers(u, id).map { Item(url: $0, size: allocSize($0)) }
            s.apps.append(AppEntry(url: u, name: u.deletingPathExtension().lastPathComponent, bundleID: id, size: allocSize(u), leftovers: leftovers))
        }
    }
    // A folder claimed by two apps (two copies of one app, or two apps with one name) is shared:
    // uninstalling one app must not take the other app's data.
    let claims = Dictionary(grouping: s.apps.flatMap { $0.leftovers.map { $0.url.path.lowercased() } }, by: { $0 }).mapValues(\.count)
    s.apps = s.apps.map { a in
        AppEntry(url: a.url, name: a.name, bundleID: a.bundleID, size: a.size, leftovers: a.leftovers.filter { claims[$0.url.path.lowercased()] == 1 })
    }
    // An app's log folder counts once, under the app, not again under temporary files.
    s.temp.removeAll { claims[$0.url.path.lowercased()] != nil }
    s.apps.sort { $0.total > $1.total }
    s.done = true
    return s
}

// Support folders: the exact bundle-ID names above, plus folders named exactly like the app
// (Application Support/Claude, Application Support/Google/Chrome), same case. Never fuzzy matches, never the
// vendor folder itself (Microsoft, Google), and never a name that one of the macOS apps uses.
func appLeftovers(_ app: URL, _ id: String) -> [URL] {
    var urls = leftoverPatterns.map { home.appending(path: "\($0.dir)/\(id)\($0.suffix)") }
    let info = Bundle(url: app)?.infoDictionary ?? [:]
    let names = Set([info["CFBundleName"] as? String, app.deletingPathExtension().lastPathComponent]
        .compactMap { $0 }.filter { n in
            n.count >= 3 && !n.contains("/") && !["", "Utilities/"].contains { fm.fileExists(atPath: "/System/Applications/\($0)\(n).app") }
        })
    let vendor = id.split(separator: ".").dropFirst().first?.lowercased()  // com.google.Chrome -> google
    for dir in ["Library/Application Support", "Library/Caches", "Library/Logs"] {
        let base = home.appending(path: dir), entries = children(base)
        // Exact case: an app called "claude" never takes the "Claude" folder (the disk itself ignores case).
        let vendorDir = entries.first { $0.lastPathComponent.lowercased() == vendor }  // real name, e.g. "Google"
        let inVendor = vendorDir.map(children) ?? []
        for n in names {
            urls += entries.filter { $0.lastPathComponent == n } + inVendor.filter { $0.lastPathComponent == n }
        }
    }
    var seen = Set<String>()
    return urls.filter { fm.fileExists(atPath: $0.path) && seen.insert($0.path.lowercased()).inserted }
}

// Temp items: owned by you, untouched for a day, with no socket or pipe inside (those belong to
// running programs, e.g. a database or tmux). Apple's own temp items never appear.
private func tempItems(_ dir: URL) -> [Item] {
    let dayAgo = Date().addingTimeInterval(-86_400)
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileResourceTypeKey, .totalFileAllocatedSizeKey]
    return children(dir).compactMap { u in
        guard !u.lastPathComponent.hasPrefix("com.apple."),
              (try? fm.attributesOfItem(atPath: u.path)[.ownerAccountID] as? Int) == Int(getuid()) else { return nil }
        let inside = fm.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })?.allObjects as? [URL]
        var size: Int64 = 0, newest = Date.distantPast
        for f in [u] + (inside ?? []) {
            guard let v = try? f.resourceValues(forKeys: keys) else { return nil }  // unreadable: leave it alone
            if v.fileResourceType == .socket || v.fileResourceType == .namedPipe { return nil }
            size += Int64(v.totalFileAllocatedSize ?? 0)
            newest = max(newest, v.contentModificationDate ?? .distantPast)
        }
        return newest < dayAgo && size > 0 ? Item(url: u, size: size, date: newest) : nil
    }
}
