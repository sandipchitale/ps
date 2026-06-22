import Foundation
import Observation

// Bundle of per-process details shown in the inspector window.
struct ProcDetail: Sendable {
    var command: String = ""
    var workingDirectory: String? = nil
    var environment: [String] = []
    var groups: [String] = []
    var ports: [PortRow] = []
    var systemProperties: [String] = [] // JVM system properties (Java processes only)
    var elevated: Bool = false          // fetched via sudo
    var cwdDenied: Bool = false         // cwd unreadable without privileges
    var envDenied: Bool = false         // env unreadable without privileges
}

@Observable @MainActor
final class ProcessMonitor {
    // Observable state
    var records: [ProcRecord] = []
    var isRefreshing = false
    var lastError: String? = nil
    var lastRefreshedDate: Date? = Date()

    enum ViewMode: String, CaseIterable, Identifiable, Hashable {
        case table, tree
        var id: String { rawValue }
    }

    // View / filter configuration
    var viewMode: ViewMode = .table { didSet { markDisplayUpdated() } }
    var searchText = "" { didSet { markDisplayUpdated() } }
    var showMyProcessesOnly = true { didSet { markDisplayUpdated() } }
    var deepSearch = false { didSet { if deepSearch { enrichVisible() }; markDisplayUpdated() } }

    // Auto-refresh
    var isAutoRefreshEnabled = false { didSet { setupTimer() } }
    var refreshInterval: Double = 5.0 { didSet { setupTimer() } }

    // Sorting (defaults to ascending PID)
    var sortOrder = [KeyPathComparator(\ProcNode.pid, order: .forward)]

    // The tab a freshly-opened (or re-focused) inspector window should show,
    // keyed by pid. Set just before openWindow so the window can pick it up.
    var pendingDetailTab: [Int: ProcessDetailWindow.DetailTab] = [:]

    // Cache of cwd/env strings used only for deep search (keyed by pid).
    private var searchCache: [Int: (cwd: String, env: String)] = [:]

    private var refreshTask: Task<Void, Never>? = nil
    private let myUID = Int(getuid())

    init() {
        setupTimer()
        refresh()
    }

    private func markDisplayUpdated() { lastRefreshedDate = Date() }

    func setupTimer() {
        refreshTask?.cancel()
        refreshTask = nil
        guard isAutoRefreshEnabled else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = self.refreshInterval
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
                if Task.isCancelled { break }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                var parsed = try await ProcessMonitor.fetchProcesses()
                async let portsTask = ProcessMonitor.fetchPortCounts()
                async let javaTask = ProcessMonitor.fetchJavaPIDs()
                let ports = await portsTask
                let javaPIDs = await javaTask
                for i in parsed.indices {
                    parsed[i].portCount = ports[parsed[i].pid] ?? 0
                    parsed[i].isJava = javaPIDs.contains(parsed[i].pid) || parsed[i].commandSuggestsJava
                }
                self.records = parsed
                self.lastRefreshedDate = Date()
                self.lastError = nil
                self.isRefreshing = false
                if self.deepSearch { self.enrichVisible() }
            } catch {
                self.isRefreshing = false
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Filtering

    var filteredRecords: [ProcRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { rec in
            if showMyProcessesOnly && rec.uid != myUID { return false }
            if query.isEmpty { return true }
            if rec.command.lowercased().contains(query) { return true }
            if rec.user.lowercased().contains(query) { return true }
            if String(rec.pid).contains(query) { return true }
            if String(rec.ppid).contains(query) { return true }
            if deepSearch, let cached = searchCache[rec.pid] {
                if cached.cwd.lowercased().contains(query) { return true }
                if cached.env.lowercased().contains(query) { return true }
            }
            return false
        }
    }

    // Flat list as ProcNodes (depth 0), sorted by the active sort order.
    var flatNodes: [ProcNode] {
        var nodes = filteredRecords.map { ProcNode(record: $0) }
        nodes.sort(using: sortOrder)
        return nodes
    }

    // Process tree flattened into DFS order with a depth on each node, so the
    // tree always renders fully expanded. Siblings are ordered by the active
    // sort order. Parents that are filtered out but have visible descendants
    // are kept as connective tissue.
    var treeFlatNodes: [ProcNode] {
        let visible = filteredRecords
        let visiblePIDs = Set(visible.map(\.pid))

        // Always index by the full record set so we can walk to real parents.
        let byPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
        let childrenByPPID = Dictionary(grouping: records, by: \.ppid)

        // Include visible pids plus all ancestors of visible pids.
        var include = visiblePIDs
        for rec in visible {
            var p = rec.ppid
            var guardCount = 0
            while let parent = byPID[p], !include.contains(parent.pid), guardCount < 10_000 {
                include.insert(parent.pid)
                p = parent.ppid
                guardCount += 1
            }
        }

        func sortedRecords(_ recs: [ProcRecord]) -> [ProcRecord] {
            recs.map { ProcNode(record: $0) }.sorted(using: sortOrder).map(\.record)
        }

        var result: [ProcNode] = []
        var emitted = Set<Int>()
        func emit(_ rec: ProcRecord, _ depth: Int) {
            guard emitted.insert(rec.pid).inserted else { return }   // guard against cycles
            result.append(ProcNode(record: rec, depth: depth))
            let kids = (childrenByPPID[rec.pid] ?? [])
                .filter { include.contains($0.pid) && $0.pid != rec.pid }
            for kid in sortedRecords(kids) { emit(kid, depth + 1) }
        }

        let roots = records.filter { rec in
            include.contains(rec.pid) && (byPID[rec.ppid] == nil || !include.contains(rec.ppid) || rec.ppid == rec.pid)
        }
        for root in sortedRecords(roots) { emit(root, 0) }
        return result
    }

    // MARK: - Deep-search enrichment

    private func enrichVisible() {
        let pids = filteredRecords.map(\.pid).filter { searchCache[$0] == nil }
        guard !pids.isEmpty else { return }
        Task.detached(priority: .utility) {
            var updates: [Int: (String, String)] = [:]
            for pid in pids {
                let cwd = await ProcessMonitor.fetchWorkingDirectory(pid: pid) ?? ""
                let env = await ProcessMonitor.fetchEnvironment(pid: pid).joined(separator: "\n")
                updates[pid] = (cwd, env)
            }
            await MainActor.run {
                for (pid, v) in updates { self.searchCache[pid] = v }
                self.markDisplayUpdated()
            }
        }
    }

    // MARK: - ps listing

    nonisolated private static func fetchProcesses() async throws -> [ProcRecord] {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            // Fixed-width single-token fields, then command= last (may contain spaces).
            process.arguments = ["-axww", "-o", "pid=,ppid=,uid=,user=,%cpu=,%mem=,stat=,start=,command="]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(separator: "\n").compactMap(parseLine)
        }.value
    }

    // Parse one `ps` line: 8 leading single-token fields, then the command remainder.
    nonisolated private static func parseLine(_ line: Substring) -> ProcRecord? {
        let chars = Array(line)
        var i = 0
        let n = chars.count
        func skipSpaces() { while i < n && chars[i] == " " { i += 1 } }
        func token() -> String {
            skipSpaces()
            let start = i
            while i < n && chars[i] != " " { i += 1 }
            return String(chars[start..<i])
        }
        guard let pid = Int(token()) else { return nil }
        guard let ppid = Int(token()) else { return nil }
        guard let uid = Int(token()) else { return nil }
        let user = token()
        let cpu = Double(token()) ?? 0
        let mem = Double(token()) ?? 0
        let stat = token()
        let start = token()
        skipSpaces()
        let command = String(chars[min(i, n)..<n])
        if command.isEmpty { return nil }
        return ProcRecord(pid: pid, ppid: ppid, uid: uid, user: user,
                          cpu: cpu, mem: mem, stat: stat, start: start, command: command)
    }

    // Global lsof pass mapping pid -> number of open TCP endpoints.
    nonisolated private static func fetchPortCounts() async -> [Int: Int] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-iTCP", "-Fp"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { return [:] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return [:] }
            var counts: [Int: Int] = [:]
            for line in out.split(separator: "\n") where line.hasPrefix("p") {
                if let pid = Int(line.dropFirst()) { counts[pid, default: 0] += 1 }
            }
            return counts
        }.value
    }

    // PIDs of all JVM processes, via `jps` (authoritative for the current user).
    // Output is "<pid> <name>" lines; the leading token is the PID. Returns an
    // empty set if no jps is found, in which case detection falls back to the
    // command-line heuristic.
    nonisolated private static func fetchJavaPIDs() async -> Set<Int> {
        await Task.detached(priority: .utility) {
            guard let jps = jpsPath() else { return [] }
            let out = runCapture(jps, [])
            var pids = Set<Int>()
            for line in out.split(separator: "\n") {
                if let tok = line.split(separator: " ").first, let pid = Int(tok) {
                    pids.insert(pid)
                }
            }
            return pids
        }.value
    }

    // Finds a usable jps: the system stub, else the default JDK's bin/jps.
    nonisolated private static func jpsPath() -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/usr/bin/jps") { return "/usr/bin/jps" }
        let home = runCapture("/usr/libexec/java_home", [])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty {
            let candidate = (home as NSString).appendingPathComponent("bin/jps")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Per-process detail (own processes)

    nonisolated static func fetchFullCommand(pid: Int) async -> String {
        await Task.detached(priority: .userInitiated) {
            runCapture("/bin/ps", ["-ww", "-o", "command=", "-p", String(pid)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    nonisolated static func fetchWorkingDirectory(pid: Int) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let out = runCapture("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", String(pid), "-Fn", "-P", "-n"])
            for line in out.split(separator: "\n") where line.hasPrefix("n") {
                let path = String(line.dropFirst())
                return path.isEmpty ? nil : path
            }
            return nil
        }.value
    }

    nonisolated static func fetchGroups(uid: Int) async -> [String] {
        await Task.detached(priority: .utility) {
            let out = runCapture("/usr/bin/id", ["-Gn", String(uid)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? [] : out.split(separator: " ").map(String.init)
        }.value
    }

    // Open TCP endpoints for one process, parsed into structured rows.
    nonisolated static func fetchPorts(pid: Int) async -> [PortRow] {
        await Task.detached(priority: .utility) {
            let out = runCapture("/usr/sbin/lsof", ["-nP", "-iTCP", "-a", "-p", String(pid), "-F", "ftnT"])
            return PortRow.parse(out)
        }.value
    }

    // JVM system properties via `jcmd <pid> VM.system_properties`. Uses the jcmd
    // shipped alongside the process's own `java` binary (so the attach protocol
    // matches the target's Java version), falling back to a system jcmd.
    nonisolated static func fetchSystemProperties(for rec: ProcRecord) async -> [String] {
        guard rec.isJava else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let jcmd = jcmdPath(forPid: rec.pid)
            let out = runCapture(jcmd, [String(rec.pid), "VM.system_properties"])
            return parseSystemProperties(out)
        }.value
    }

    // Locates the jcmd matching the target process's Java install: the executable
    // path comes from `ps -o comm=`, and jcmd lives next to it in the same bin/.
    nonisolated private static func jcmdPath(forPid pid: Int) -> String {
        let comm = runCapture("/bin/ps", ["-o", "comm=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !comm.isEmpty {
            let dir = (comm as NSString).deletingLastPathComponent
            let candidate = (dir as NSString).appendingPathComponent("jcmd")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/jcmd"  // PATH/system fallback
    }

    // Parses `jcmd … VM.system_properties` (Java .properties format): drops the
    // "<pid>:" header and "#"-comments, splits each "key=value" on the first
    // unescaped '=', and unescapes Java property escapes. Returns sorted entries.
    nonisolated static func parseSystemProperties(_ output: String) -> [String] {
        var props: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("#") { continue }
            if line.hasSuffix(":"), Int(line.dropLast()) != nil { continue }  // "<pid>:" header
            guard let eq = firstUnescapedEquals(line) else { continue }
            let key = unescapeProperty(String(line[line.startIndex..<eq]))
            let value = unescapeProperty(String(line[line.index(after: eq)...]))
            props.append("\(key)=\(value)")
        }
        return props.sorted()
    }

    nonisolated private static func firstUnescapedEquals(_ s: String) -> String.Index? {
        var idx = s.startIndex
        var escaped = false
        while idx < s.endIndex {
            let c = s[idx]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "=" { return idx }
            idx = s.index(after: idx)
        }
        return nil
    }

    // Unescapes \\, \=, \:, \ , \#, \uXXXX etc. Keeps \n/\r/\t/\f as their literal
    // two-character form so each property stays on a single display line.
    nonisolated private static func unescapeProperty(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "n", "r", "t", "f":
                    out.append("\\"); out.append(n)  // keep readable, single-line
                case "u" where i + 5 < chars.count:
                    if let code = UInt32(String(chars[(i + 2)...(i + 5)]), radix: 16),
                       let scalar = Unicode.Scalar(code) {
                        out.append(Character(scalar)); i += 6; continue
                    }
                    out.append(n)
                default:
                    out.append(n)  // \: \= \\ \space \# … -> literal
                }
                i += 2
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }

    // Environment via KERN_PROCARGS2 (works only for own processes).
    nonisolated static func fetchEnvironment(pid: Int) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
            var size = 0
            if sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) != 0 || size == 0 { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            if sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) != 0 { return [] }
            return buffer.withUnsafeBufferPointer { ptr -> [String] in
                guard let base = ptr.baseAddress, size >= MemoryLayout<Int32>.size else { return [] }
                let total = size
                var offset = 0
                var argc: Int32 = 0
                memcpy(&argc, base, MemoryLayout<Int32>.size)
                offset = MemoryLayout<Int32>.size
                func nextString() -> String? {
                    guard offset < total else { return nil }
                    let start = offset
                    while offset < total && base[offset] != 0 { offset += 1 }
                    guard offset < total else { return nil }
                    let s = String(cString: base + start)
                    offset += 1
                    return s
                }
                _ = nextString()  // exec_path
                while offset < total && base[offset] == 0 { offset += 1 }
                var consumed: Int32 = 0
                while consumed < argc, nextString() != nil { consumed += 1 }
                var env: [String] = []
                while offset < total {
                    while offset < total && base[offset] == 0 { offset += 1 }
                    guard let s = nextString(), !s.isEmpty else { break }
                    env.append(s)
                }
                return env.sorted()
            }
        }.value
    }

    /// Fetch everything for a process. For our own processes this uses the
    /// normal (no-prompt) paths. When `elevate` is true it issues a single
    /// administrator-authenticated shell script to read another user's process.
    nonisolated static func fetchDetail(for rec: ProcRecord, elevate: Bool) async -> ProcDetail {
        if elevate {
            return await fetchDetailElevated(rec: rec)
        }
        async let cmd = fetchFullCommand(pid: rec.pid)
        async let cwd = fetchWorkingDirectory(pid: rec.pid)
        async let env = fetchEnvironment(pid: rec.pid)
        async let groups = fetchGroups(uid: rec.uid)
        async let ports = fetchPorts(pid: rec.pid)
        async let sysProps = fetchSystemProperties(for: rec)
        var d = ProcDetail()
        d.command = await cmd
        d.workingDirectory = await cwd
        d.environment = await env
        d.groups = await groups
        d.ports = await ports
        d.systemProperties = await sysProps
        d.cwdDenied = (d.workingDirectory == nil)
        d.envDenied = d.environment.isEmpty
        return d
    }

    // MARK: - Sudo escalation (one prompt gathers everything)

    nonisolated private static func fetchDetailElevated(rec: ProcRecord) async -> ProcDetail {
        let pid = rec.pid
        // For Java processes, also try jcmd (matching the target's java install)
        // under elevated rights to read VM system properties.
        let sysPropsCmd = rec.isJava ? """
        echo '<<<SYSPROPS>>>'
        COMM=$(/bin/ps -o comm= -p $P 2>/dev/null)
        JCMD="$(/usr/bin/dirname "$COMM")/jcmd"
        [ -x "$JCMD" ] || JCMD=/usr/bin/jcmd
        "$JCMD" $P VM.system_properties 2>/dev/null
        """ : ""
        let script = """
        P=\(pid)
        echo '<<<CWD>>>'
        /usr/sbin/lsof -a -d cwd -p $P -Fn 2>/dev/null | /usr/bin/awk '/^n/{print substr($0,2); exit}'
        echo '<<<CMD>>>'
        /bin/ps -ww -o command= -p $P 2>/dev/null
        echo '<<<ENVFULL>>>'
        /bin/ps eww -o command= -p $P 2>/dev/null
        echo '<<<PORTS>>>'
        /usr/sbin/lsof -nP -iTCP -a -p $P -F ftnT 2>/dev/null
        \(sysPropsCmd)
        echo '<<<END>>>'
        """
        let output = await runSudoScript(script)

        func section(_ name: String) -> String {
            guard let start = output.range(of: "<<<\(name)>>>\n") else { return "" }
            let rest = output[start.upperBound...]
            if let next = rest.range(of: "\n<<<") {
                return String(rest[..<next.lowerBound])
            }
            return String(rest)
        }

        var d = ProcDetail()
        d.elevated = true
        let cwd = section("CWD").trimmingCharacters(in: .whitespacesAndNewlines)
        d.workingDirectory = cwd.isEmpty ? nil : cwd
        d.cwdDenied = (d.workingDirectory == nil)
        d.command = section("CMD").trimmingCharacters(in: .whitespacesAndNewlines)
        let full = section("ENVFULL").trimmingCharacters(in: .whitespacesAndNewlines)
        d.environment = extractEnvironment(command: d.command, full: full)
        d.envDenied = d.environment.isEmpty
        d.ports = PortRow.parse(section("PORTS"))
        if rec.isJava { d.systemProperties = parseSystemProperties(section("SYSPROPS")) }
        d.groups = await fetchGroups(uid: rec.uid)
        return d
    }

    // `ps eww -o command=` prints the command followed by the environment.
    // Strip the known command prefix, then split the remainder into KEY=value
    // entries (env values may contain spaces, so we re-attach continuation
    // tokens that don't begin a new KEY=).
    nonisolated private static func extractEnvironment(command: String, full: String) -> [String] {
        var tail = full
        if tail.hasPrefix(command) {
            tail = String(tail.dropFirst(command.count))
        }
        tail = tail.trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return [] }

        func isKey(_ s: Substring) -> Bool {
            guard let eq = s.firstIndex(of: "=") else { return false }
            let key = s[s.startIndex..<eq]
            if key.isEmpty { return false }
            for (idx, ch) in key.enumerated() {
                if idx == 0 && !(ch.isLetter || ch == "_") { return false }
                if !(ch.isLetter || ch.isNumber || ch == "_") { return false }
            }
            return true
        }

        var result: [String] = []
        var current = ""
        for token in tail.split(separator: " ", omittingEmptySubsequences: true) {
            if isKey(token) {
                if !current.isEmpty { result.append(current) }
                current = String(token)
            } else if current.isEmpty {
                current = String(token)
            } else {
                current += " " + token
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.sorted()
    }

    // Write the script to a temp file and run it via osascript with admin rights
    // (single authentication prompt). Returns combined stdout.
    nonisolated private static func runSudoScript(_ script: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("psmon-\(UUID().uuidString).sh")
            do { try script.write(to: tmp, atomically: true, encoding: .utf8) } catch { return "" }
            defer { try? FileManager.default.removeItem(at: tmp) }
            let appleScript = "do shell script \"/bin/bash \(tmp.path)\" with administrator privileges"
            return runCapture("/usr/bin/osascript", ["-e", appleScript])
        }.value
    }

    // MARK: - Kill

    nonisolated static func performKill(pid: Int, useSudo: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            if useSudo {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "do shell script \"kill -9 \(pid)\" with administrator privileges"]
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/kill")
                process.arguments = ["-9", String(pid)]
            }
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let msg = useSudo ? "Sudo authentication cancelled or failed."
                                  : "Failed to kill process (try Sudo Kill)."
                throw NSError(domain: "KillError", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }.value
    }

    func killProcess(pid: Int, useSudo: Bool) async throws {
        try await ProcessMonitor.performKill(pid: pid, useSudo: useSudo)
        refresh()
    }

    // MARK: - Shared subprocess helper

    nonisolated private static func runCapture(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
