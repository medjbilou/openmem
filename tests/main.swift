// SPDX-License-Identifier: GPL-3.0-or-later
// Safety self-checks. Run with ./test.sh. Only a new temp folder is written to; nothing is moved to the Trash.

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

print(failures == 0 ? "all safety checks passed" : "\(failures) safety checks failed")
exit(failures == 0 ? 0 : 1)
