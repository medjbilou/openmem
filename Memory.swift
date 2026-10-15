// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMem — free, open-source memory and disk cleaner for macOS.

import AppKit
import Darwin

struct MemStats {
    var total = 0.0, used = 0.0, free = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0
    var pct: Int { total > 0 ? Int((used / total * 100).rounded()) : 0 }
}

// Same formula as Activity Monitor's "Memory Used": app memory + wired + compressed.
func readMem() -> MemStats {
    var s = MemStats(total: Double(ProcessInfo.processInfo.physicalMemory))
    var vm = vm_statistics64()
    var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
    }
    guard ok == KERN_SUCCESS else { return s }
    let page = Double(vm_kernel_page_size)
    let app = max(0, Double(vm.internal_page_count) - Double(vm.purgeable_count)) * page
    s.wired = Double(vm.wire_count) * page
    s.compressed = Double(vm.compressor_page_count) * page
    s.cached = (Double(vm.external_page_count) + Double(vm.purgeable_count)) * page
    s.free = Double(vm.free_count) * page
    s.used = app + s.wired + s.compressed
    return s
}

struct HeavyApp: Identifiable {
    let app: NSRunningApplication
    let bytes: Double
    var id: pid_t { app.processIdentifier }
    var name: String { app.localizedName ?? "?" }
}

// Groups helper processes (renderers, XPC services) under the app that owns them, like Activity Monitor.
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsiblePid: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

private func footprint(_ pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return r == 0 ? info.ri_phys_footprint : nil
}

private func allPids() -> [pid_t] {
    var buf = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let n = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    return Array(buf.prefix(max(0, Int(n))))
}

// No subprocess spawn: one syscall per pid, a few ms total.
@MainActor func heavyApps(limit: Int = 5) -> [HeavyApp] {
    var apps: [pid_t: NSRunningApplication] = [:]
    for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { apps[a.processIdentifier] = a }
    var sums: [pid_t: UInt64] = [:]
    for pid in allPids() {
        guard let fp = footprint(pid) else { continue }
        let owner = responsiblePid?(pid) ?? pid
        if apps[owner] != nil { sums[owner, default: 0] += fp }
    }
    return sums.sorted { $0.value > $1.value }.prefix(limit).compactMap { pid, b in
        apps[pid].map { HeavyApp(app: $0, bytes: Double(b)) }
    }
}

enum Purge {
    static let sudoers = "/etc/sudoers.d/openmem"
    // Fixed args: 1 s of simulated "warn" pressure, then the tool itself resets the level to normal.
    // Never kill it early: the reset only runs after its sleep, so a kill would leave the Mac at "warn".
    static let pressure = "/usr/bin/memory_pressure -S -l warn -s 1"
    static let ruleVersion = 2  // v1 allowed purge only; older installs ask for the password once more to upgrade
    static var passwordless: Bool {
        UserDefaults.standard.integer(forKey: "sudoersVersion") >= ruleVersion && FileManager.default.fileExists(atPath: sudoers)
    }

    // Three steps:
    // 1. sync: write dirty file pages to disk. purge only calls vfs_purge, so dirty pages would stay.
    // 2. Simulated warn pressure: every app gets a low-memory notification and the kernel drops purgeable memory.
    //    This lowers app memory, not only the file cache.
    // 3. purge: drop the file cache. Skipped on auto runs: the Mac stalls while caches refill.
    static func run(dropFileCache: Bool) -> Bool {
        if !passwordless, !enablePasswordless() { return false }
        sync()
        guard sh("/usr/bin/sudo", ["-n"] + pressure.split(separator: " ").map(String.init)) else { return false }
        return !dropFileCache || sh("/usr/bin/sudo", ["-n", "/usr/sbin/purge"])
    }

    // Rule allows only purge and the exact memory_pressure call above; visudo validates it before install so sudo can't break.
    static func enablePasswordless() -> Bool {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/sbin/purge, \(pressure)"
        let ok = asAdmin("t=$(mktemp) && echo '\(rule)' > $t && /usr/sbin/visudo -cf $t && install -m 0440 -o root -g wheel $t \(sudoers); rc=$?; rm -f $t; exit $rc")
        if ok { UserDefaults.standard.set(ruleVersion, forKey: "sudoersVersion") }
        return ok
    }

    static func disablePasswordless() -> Bool { asAdmin("rm -f \(sudoers)") }

    static func asAdmin(_ cmd: String) -> Bool {
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return sh("/usr/bin/osascript", ["-e", "do shell script \"\(esc)\" with administrator privileges"])
    }
}

@discardableResult func sh(_ exe: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func fmtMem(_ b: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }
func fmtDisk(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
