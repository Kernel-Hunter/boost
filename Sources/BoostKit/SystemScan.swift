import AppKit
import Darwin

enum SystemScan {

    // MARK: - Process table

    /// Samples the process table natively. The previous implementation shelled out
    /// to `ps`, which cost ~111 ms per refresh; this costs ~4 ms, because it makes
    /// the same kernel calls without a fork/exec and caches what cannot change.
    ///
    /// Note: `ps` is setuid root and can read RSS for every process. We run as you,
    /// so memory for root-owned daemons is unreadable and reported as unknown
    /// rather than as zero. Those are all processes you could not signal anyway.
    ///
    /// Main-actor confined: it carries mutable state across calls (the path
    /// cache and the previous CPU counters that make a percentage possible),
    /// and every caller is already on the main actor. Saying so lets the
    /// compiler prove there is no race, rather than us assuming it.
    @MainActor
    final class Sampler {
        static let shared = Sampler()

        private var pathCache: [pid_t: (start: Int, path: String)] = [:]
        private var prevCPU: [pid_t: UInt64] = [:]
        private var prevStamp = Date()

        private func allProcesses() -> [kinfo_proc] {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            for _ in 0..<4 {
                var size = 0
                guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
                let capacity = size / MemoryLayout<kinfo_proc>.stride + 32   // headroom: procs can spawn between the two calls
                var buf = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
                var used = capacity * MemoryLayout<kinfo_proc>.stride
                if sysctl(&mib, 4, &buf, &used, nil, 0) == 0 {
                    return Array(buf.prefix(used / MemoryLayout<kinfo_proc>.stride))
                }
                if errno != ENOMEM { return [] }
            }
            return []
        }

        func sample() -> [pid_t: ProcSample] {
            let procs = allProcesses()
            let now = Date()
            let elapsed = max(now.timeIntervalSince(prevStamp), 0.001)
            prevStamp = now

            var out: [pid_t: ProcSample] = [:]
            out.reserveCapacity(procs.count)
            var cpuNow: [pid_t: UInt64] = [:]
            cpuNow.reserveCapacity(procs.count)
            var pathBuf = [CChar](repeating: 0, count: 4096)

            for proc in procs {
                let pid = proc.kp_proc.p_pid
                guard pid > 0 else { continue }
                let startSec = Int(proc.kp_proc.p_starttime.tv_sec)

                // A process's executable path never changes, so look it up once.
                // Keyed on start time as well, so a recycled pid can't inherit it.
                let path: String
                if let hit = pathCache[pid], hit.start == startSec {
                    path = hit.path
                } else {
                    let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
                    path = n > 0 ? String(cString: pathBuf)
                                 : withUnsafePointer(to: proc.kp_proc.p_comm) {
                                       $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                                           String(cString: $0)
                                       }
                                   }
                    pathCache[pid] = (startSec, path)
                }

                var rss: UInt64 = 0
                var known = false
                var ri = rusage_info_v4()
                let ok = withUnsafeMutablePointer(to: &ri) { ptr in
                    ptr.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                    }
                }
                var cpuPct = 0.0
                if ok == 0 {
                    rss = ri.ri_resident_size
                    known = true
                    let total = ri.ri_user_time &+ ri.ri_system_time      // nanoseconds, cumulative
                    cpuNow[pid] = total
                    if let was = prevCPU[pid], total >= was {
                        cpuPct = Double(total - was) / (elapsed * 1_000_000_000) * 100
                    }
                }

                out[pid] = ProcSample(
                    pid: pid,
                    ppid: proc.kp_eproc.e_ppid,
                    rssBytes: rss,
                    rssKnown: known,
                    cpu: cpuPct,
                    stopped: proc.kp_proc.p_stat == SSTOP,
                    path: path
                )
            }

            prevCPU = cpuNow                                  // dead pids drop out on their own
            if pathCache.count > procs.count * 2 {            // keep the cache from growing forever
                pathCache = pathCache.filter { out[$0.key] != nil }
            }
            return out
        }
    }

    @MainActor
    static func sampleProcesses() -> [pid_t: ProcSample] { Sampler.shared.sample() }

    /// Every descendant of `root`, so an Electron app's dozen helpers count as one thing.
    ///
    /// Tracks what it has already walked. A parent chain is a tree in principle
    /// and a cycle is not supposed to be expressible, but pid reuse can produce
    /// one: a process's parent exits, the number is handed out again, and the
    /// new holder is a child of the original. We resample every two seconds, so
    /// a window that small is reached eventually. Without this set that costs an
    /// unbounded loop appending forever — on an app whose entire job is
    /// reclaiming memory, the failure would be exhausting it.
    static func descendants(of root: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        var found: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var queue = children[root] ?? []
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            found.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return found
    }

    // MARK: - Building the item list

    @MainActor
    static func buildItems(procs: [pid_t: ProcSample] = sampleProcesses()) -> [Item] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, s) in procs { children[s.ppid, default: []].append(pid) }

        var items: [Item] = []
        var claimed = Set<pid_t>()

        // --- 1. Real applications and agents, via NSWorkspace (gives us icons + polite quit)
        var byName: [String: Int] = [:]   // localizedName -> index in `items`

        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier > 0 && !$0.isTerminated
        }

        // WebKit farms out rendering to XPC processes parented to launchd, named
        // "<App> Web Content" / "Networking" / "Graphics and Media". Fold them into
        // their owner instead of listing them as mystery entries.
        let helperSuffixes = [" Web Content", " Networking", " Graphics and Media"]
        var deferredHelpers: [(owner: String, app: NSRunningApplication)] = []

        for app in running {
            let name = app.localizedName ?? "Unknown"
            if let suffix = helperSuffixes.first(where: { name.hasSuffix($0) }) {
                deferredHelpers.append((String(name.dropLast(suffix.count)), app))
                continue
            }

            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            let path = app.bundleURL?.path ?? procs[pid]?.path ?? ""
            let isApple = Guard.isSystemPath(path)

            let category: Category
            if Guard.isProtected(id: bundleID ?? path, name: name) {
                category = .system
            } else if app.activationPolicy == .regular {
                category = .app          // it has windows; you opened it, you can close it
            } else {
                category = isApple ? .system : .agent
            }

            var pids = [pid] + descendants(of: pid, children: children)
            pids = pids.filter { procs[$0] != nil }
            claimed.formUnion(pids)

            items.append(Item(
                baseID: bundleID ?? path,
                id: bundleID ?? path,
                name: name,
                category: category,
                isAppleSoftware: isApple,
                pids: pids,
                rssBytes: pids.reduce(0) { $0 + (procs[$1]?.rssBytes ?? 0) },
                rssKnown: pids.contains { procs[$0]?.rssKnown ?? false },
                cpu: pids.reduce(0) { $0 + (procs[$1]?.cpu ?? 0) },
                isPaused: pids.allSatisfy { procs[$0]?.stopped ?? false } && !pids.isEmpty,
                bundlePath: path.isEmpty ? nil : path,
                runningAppPID: pid
            ))
            byName[name] = items.count - 1
        }

        for (owner, helper) in deferredHelpers {
            let hpids = ([helper.processIdentifier]
                + descendants(of: helper.processIdentifier, children: children))
                .filter { procs[$0] != nil }
            claimed.formUnion(hpids)
            let bytes = hpids.reduce(0) { $0 + (procs[$1]?.rssBytes ?? 0) }
            let cpu = hpids.reduce(0) { $0 + (procs[$1]?.cpu ?? 0) }

            if let idx = byName[owner] {
                items[idx].pids.append(contentsOf: hpids)
                items[idx].rssBytes += bytes
                items[idx].cpu += cpu
            } else if !hpids.isEmpty {
                // Owner has gone; show it rather than hide the memory.
                let bid = helper.bundleIdentifier ?? (helper.localizedName ?? "helper")
                items.append(Item(
                    baseID: bid, id: bid,
                    name: helper.localizedName ?? owner,
                    category: .system,
                    isAppleSoftware: true,
                    pids: hpids, rssBytes: bytes,
                    rssKnown: hpids.contains { procs[$0]?.rssKnown ?? false }, cpu: cpu,
                    isPaused: hpids.allSatisfy { procs[$0]?.stopped ?? false },
                    bundlePath: helper.bundleURL?.path, runningAppPID: helper.processIdentifier))
            }
        }

        // --- 2. Widget extensions (.appex) — these never appear in runningApplications
        for (pid, s) in procs where !claimed.contains(pid) && s.path.contains(".appex/") {
            guard let range = s.path.range(of: ".appex") else { continue }
            let appexPath = String(s.path[..<range.upperBound])
            let widgetName = ((appexPath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            let pids = [pid] + descendants(of: pid, children: children)
            claimed.formUnion(pids)

            items.append(Item(
                baseID: appexPath,
                id: appexPath,
                name: prettifyWidget(widgetName),
                category: .widget,
                isAppleSoftware: Guard.isSystemPath(s.path),
                pids: pids,
                rssBytes: pids.reduce(0) { $0 + (procs[$1]?.rssBytes ?? 0) },
                rssKnown: pids.contains { procs[$0]?.rssKnown ?? false },
                cpu: pids.reduce(0) { $0 + (procs[$1]?.cpu ?? 0) },
                isPaused: pids.allSatisfy { procs[$0]?.stopped ?? false },
                bundlePath: containingApp(of: appexPath),
                runningAppPID: nil
            ))
        }

        // Any baseID shared by more than one live item gets the pid appended —
        // every member of the group, so the result doesn't depend on sort order.
        var counts: [String: Int] = [:]
        for item in items { counts[item.baseID, default: 0] += 1 }
        for i in items.indices where counts[items[i].baseID]! > 1 {
            items[i].id = "\(items[i].baseID)#\(items[i].pids.first ?? 0)"
        }

        return items.sorted {
            $0.rssBytes == $1.rssBytes
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.rssBytes > $1.rssBytes
        }
    }

    /// "CalendarWidgetExtension" -> "Calendar Widget"
    static func prettifyWidget(_ raw: String) -> String {
        var s = raw
        if s.contains("."), let tail = s.split(separator: ".").last { s = String(tail) }
        for junk in ["Extension", "Secure", "Intents"] where s.hasSuffix(junk) && s.count > junk.count {
            s = String(s.dropLast(junk.count))
        }
        let chars = Array(s)
        var spaced = ""
        for (i, ch) in chars.enumerated() {
            if i > 0, ch.isUppercase, !chars[i - 1].isUppercase { spaced.append(" ") }
            spaced.append(ch)
        }
        return spaced.trimmingCharacters(in: .whitespaces)
    }

    /// /Applications/Foo.app/Contents/PlugIns/Bar.appex -> /Applications/Foo.app (for the icon)
    static func containingApp(of appexPath: String) -> String? {
        guard let r = appexPath.range(of: ".app/") else { return nil }
        return String(appexPath[..<r.upperBound]).dropLast().description
    }

    // MARK: - Memory

    static func memory() -> MemStats {
        var m = MemStats()
        m.total = ProcessInfo.processInfo.physicalMemory

        var vmStats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return m }

        // vm_kernel_page_size is an imported mutable global, which Swift 6
        // will not vouch for. host_page_size is the supported way to ask.
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return m }
        let page = UInt64(pageSize)
        m.free       = UInt64(vmStats.free_count) * page
        m.compressed = UInt64(vmStats.compressor_page_count) * page
        m.cached     = (UInt64(vmStats.inactive_count) + UInt64(vmStats.purgeable_count)
                        + UInt64(vmStats.speculative_count)) * page
        let wired    = UInt64(vmStats.wire_count) * page
        let active   = UInt64(vmStats.active_count) * page
        m.used       = active + wired + m.compressed

        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
            m.swapUsed = usage.xsu_used
        }
        return m
    }
}
