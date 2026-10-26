// SPDX-License-Identifier: GPL-3.0-or-later
// Safety and reliability self-checks. Run with ./test.sh. Writes only to a temp folder and one file in ~/Documents
// that it deletes again; nothing is moved to the Trash.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL:", what) }
}
func h(_ p: String) -> URL { home.appending(path: p) }

// The disk space map can't reach ~/Library app data, caches, temp folders or Apple's files.
for p in ["Library/Application Support/MobileSync/Backup/x", "Library/Application Support/Google/Chrome",
          "Library/Containers/com.example.app/Data", "Library/Preferences/com.example.plist", "Library/Caches/com.example",
          "Library/Logs/x", "Library/Keychains/login.keychain-db", ".ssh/id_ed25519", "Documents/com.apple.notes/x"] {
    check(!Safety.canTrash(h(p), picked: true), "map must refuse ~/\(p)")
}
check(!Safety.canTrash(URL(fileURLWithPath: "/private/tmp/x"), picked: true), "map must refuse /tmp")
check(!Safety.canTrash(URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "x"), picked: true), "map must refuse the temp folder")
for p in ["Documents/x", "Downloads/a/b.zip", ".npm/_cacache", "Library/Developer/Xcode/DerivedData/App-abc"] {
    check(Safety.canTrash(h(p), picked: true), "map must allow ~/\(p)")
}

// The panel's computed lists keep their wider reach, but never home itself, its secrets, or Apple's files.
for p in ["Library/Application Support/Google/Chrome", "Library/Caches/com.example", "Library/Containers/com.example.app"] {
    check(Safety.canTrash(h(p)), "lists must allow ~/\(p)")
}
for p in [".ssh/id_ed25519", "Library/Keychains/login.keychain-db", "Library/Caches/com.apple.Safari", "Documents", "Library/Caches", ".npm"] {
    check(!Safety.canTrash(h(p)), "lists must refuse ~/\(p)")
}
check(!Safety.canTrash(home), "home itself must never be trashable")

// Symlinked user folders never join the trust boundary.
let tmp = fm.temporaryDirectory.appending(path: "openmem-test-\(UUID().uuidString)")
try! fm.createDirectory(at: tmp.appending(path: "real/a/b"), withIntermediateDirectories: true)
try! fm.createSymbolicLink(at: tmp.appending(path: "link"), withDestinationURL: home)
check(isSymlink(tmp.appending(path: "link")), "isSymlink must see a symlink")
check(!isSymlink(tmp.appending(path: "real")), "isSymlink must not flag a folder")
check(!userRoots.contains(where: isSymlink), "userRoots must hold no symlink")

// lastChange looks deep: an old folder with a new file inside counts as changed.
let old = Date().addingTimeInterval(-90 * 86_400)
func age(_ u: URL) { try! fm.setAttributes([.modificationDate: old], ofItemAtPath: u.path) }
let deep = tmp.appending(path: "real/a/b/new.txt")
try! Data("x".utf8).write(to: deep)
for p in ["real/a/b", "real/a", "real"] { age(tmp.appending(path: p)) }
check(lastChange(tmp.appending(path: "real")) > Date().addingTimeInterval(-86_400), "a new file three levels down must count")
age(deep)
check(lastChange(tmp.appending(path: "real")) < Date().addingTimeInterval(-60 * 86_400), "an all-old folder must count as old")
check(lastChange(tmp.appending(path: "real"), limit: 1) > Date().addingTimeInterval(-60), "a folder over the limit must count as changed now")
try? fm.removeItem(at: tmp)

// A leftover whose ID a launch agent uses is not called removed.
let found = orphanLeftovers(installed: [], running: [], claimed: [])
if let o = found.first {
    let id = o.url.lastPathComponent
    let agent = StartupItem(url: tmp, label: id + ".agent", runs: "", missing: false)
    check(!orphanLeftovers(installed: [], running: [], claimed: [], startup: [agent]).contains { $0.url == o.url },
          "an ID used by a launch agent must not be listed")
} else { print("skip: no leftovers on this Mac to check the launch agent rule") }

// Moves use the exact path that was checked.
check(Safety.checked(h("Documents/x"))?.path == h("Documents").resolvingSymlinksInPath().path + "/x", "checked must return the resolved path")

// Generic build folders count only beside their own tool's project file.
let proj = fm.temporaryDirectory.appending(path: "openmem-test-\(UUID().uuidString)")
for d in ["make/out", "make/target", "web/dist", "web/out", "rust/target"] { try! fm.createDirectory(at: proj.appending(path: d), withIntermediateDirectories: true) }
for f in ["make/Makefile", "web/package.json", "rust/Cargo.toml"] { fm.createFile(atPath: proj.appending(path: f).path, contents: Data("x".utf8)) }
check(devItem(proj.appending(path: "make/out")) == nil && devItem(proj.appending(path: "make/target")) == nil, "out and target beside a Makefile are not build output")
check(devItem(proj.appending(path: "web/dist")) != nil && devItem(proj.appending(path: "web/out")) != nil, "dist and out beside package.json are")
check(devItem(proj.appending(path: "rust/target")) != nil, "target beside Cargo.toml is")

// A pipe, /dev/zero or an oversized junk file named .plist is skipped without blocking or filling memory.
let agents = proj.appending(path: "agents")
try! fm.createDirectory(at: agents, withIntermediateDirectories: true)
check(mkfifo(agents.appending(path: "pipe.plist").path, 0o600) == 0, "test setup: mkfifo")
fm.createFile(atPath: agents.appending(path: "huge.plist").path, contents: Data(count: 2 << 20))
try! fm.createSymbolicLink(atPath: agents.appending(path: "zero.plist").path, withDestinationPath: "/dev/zero")
try! (["Label": "com.example.ok", "Program": "/bin/true"] as NSDictionary).write(to: agents.appending(path: "ok.plist"))
let listed = startupItems([(agents, "test")])
check(listed.map(\.label) == ["com.example.ok"], "only the regular plist is read, got \(listed.map(\.label))")

MainActor.assumeIsolated {
    // A folder in the Trash, and everything inside it, can't be trashed again from the map.
    let root = Node(h("Documents").path, isDir: true, kind: .other)
    let x = Node("openmem-x", isDir: true, kind: .other), y = Node("y", isDir: false, kind: .other)
    root.children = [x]; x.parent = root; x.children = [y]; y.parent = x
    let s = SpaceModel()
    s.confirmTrash = { _, _ in false }
    check(s.canTrash(y), "test setup: item is trashable")
    x.trashed = true
    check(!s.canTrash(x) && !s.canTrash(y), "a trashed folder and its contents are not trashable")

    // An item replaced since the scan is refused before any dialog, and stays where it is.
    let file = h("Documents/openmem-selftest-\(UUID().uuidString)")
    fm.createFile(atPath: file.path, contents: Data("x".utf8))
    let r = Node(h("Documents").path, isDir: true, kind: .other), f = Node(file.lastPathComponent, isDir: false, kind: .other)
    r.children = [f]; f.parent = r
    f.fileID = ((try? file.resourceValues(forKeys: [.fileIdentifierKey]))?.fileIdentifier ?? 0) &+ 1
    s.trash(f)
    check(fm.fileExists(atPath: file.path) && s.status.contains("changed since the scan"), "a replaced item must not be moved")
    try? fm.removeItem(at: file)

    // 480 levels, built with relative steps to stay under PATH_MAX: without the depth cap the walk overflows its
    // thread's stack (SIGBUS). With it, the scan finishes and keeps the size of a file far below the cap.
    let deep = proj.appending(path: "deep"), cwd = fm.currentDirectoryPath
    try! fm.createDirectory(at: deep, withIntermediateDirectories: true)
    fm.changeCurrentDirectoryPath(deep.path)
    for level in 1...480 {
        mkdir("d", 0o755); chdir("d")
        if level == 300 { fm.createFile(atPath: "f", contents: Data(count: 1 << 20)) }  // deeper paths pass PATH_MAX
    }
    fm.changeCurrentDirectoryPath(cwd)
    s.scan(deep)
    while s.scanning { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    check((s.root?.size ?? 0) >= 1 << 20, "a 480-level tree keeps the size of a file at level 300")

    // Closing the window stops the walk: the tree never comes back after close.
    s.scan(home)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    s.close()
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    check(s.root == nil && !s.scanning, "a closed window must not reload its tree")
}
// rm, not removeItem: FileManager can't remove a tree deeper than PATH_MAX.
let rm = Process(); rm.executableURL = URL(fileURLWithPath: "/bin/rm"); rm.arguments = ["-rf", proj.path]; try? rm.run(); rm.waitUntilExit()

print(failures == 0 ? "all safety checks passed" : "\(failures) safety checks failed")
exit(failures == 0 ? 0 : 1)
