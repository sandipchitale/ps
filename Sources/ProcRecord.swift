import Foundation

// A single process as reported by `ps`. Codable/Hashable/Sendable so it can be
// passed as a SwiftUI window value (the process detail inspector).
struct ProcRecord: Identifiable, Hashable, Sendable, Codable {
    let pid: Int
    let ppid: Int
    let uid: Int
    let user: String
    let cpu: Double
    let mem: Double
    let stat: String
    let start: String
    let command: String

    // Number of open TCP endpoints, populated by a global lsof pass during
    // refresh (-1 means "not yet computed").
    var portCount: Int = -1

    var id: Int { pid }

    // The short executable name (last path component of argv[0], stripped of args).
    var name: String {
        let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }

    // Whether this is a JVM process (so the inspector can offer a "System
    // Properties" tab populated via `jcmd <pid> VM.system_properties`). Set
    // during refresh, primarily from `jps`, falling back to `commandSuggestsJava`.
    var isJava: Bool = false

    // Heuristic Java detection from the command line, used as a fallback when
    // `jps` is unavailable or can't see the process (e.g. another user's JVM).
    var commandSuggestsJava: Bool {
        if name == "java" { return true }
        let c = command
        return c.contains("/bin/java ") || c.hasSuffix("/bin/java")
            || c.contains(" -XX:") || c.contains(" -Djava.")
    }

    // Sort helpers (non-optional, Comparable).
    var cpuSortValue: Double { cpu }
    var memSortValue: Double { mem }
    var portSortValue: Int { portCount }
}

// A row in the table. In flat table mode `depth` is always 0. In tree mode the
// tree is flattened into DFS order and `depth` drives the command indentation,
// so the tree always renders fully expanded.
struct ProcNode: Identifiable, Hashable, Sendable {
    let record: ProcRecord
    var depth: Int = 0

    var id: Int { record.pid }

    // Convenience pass-throughs so TableColumn(value:) keypaths stay on ProcNode.
    var pid: Int { record.pid }
    var ppid: Int { record.ppid }
    var user: String { record.user }
    var cpu: Double { record.cpu }
    var mem: Double { record.mem }
    var stat: String { record.stat }
    var command: String { record.command }
    var portCount: Int { record.portCount }
    var isJava: Bool { record.isJava }
    var javaSortValue: Int { record.isJava ? 1 : 0 }  // Bool isn't Comparable
}
