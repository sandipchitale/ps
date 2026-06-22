import Foundation

// A single open TCP endpoint of a process, parsed from `lsof -F` output.
struct PortRow: Identifiable, Hashable, Sendable {
    let type: PortType
    let localAddress: String
    let localPort: Int?
    let remoteAddress: String?
    let remotePort: Int?
    let state: String

    var id: String {
        "\(type.rawValue)-\(localAddress):\(localPort ?? 0)->\(remoteAddress ?? "")\(remotePort ?? 0)-\(state)"
    }

    enum PortType: String, Codable, Hashable, Sendable {
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
        case dualStack = "IPv4/6"
        case unknown = "—"
    }

    // Parses machine-readable `lsof -F ftnT` output into TCP endpoints. Applies
    // the same dual-stack heuristic as the netstat app: a wildcard IPv6 listener
    // on macOS accepts IPv4 too (IPV6_V6ONLY off), so it's tagged IPv4/6.
    static func parse(_ output: String) -> [PortRow] {
        var rows: [PortRow] = []
        var type: PortType = .unknown
        var name: String? = nil
        var state = ""
        var inFile = false

        func commit() {
            guard inFile, let name else { return }
            let (la, lp, ra, rp) = parseNameField(name)
            var t = type
            if t == .ipv6 {
                if la.contains(".") && !la.contains(":") {
                    t = .ipv4
                } else if la == "*" {
                    t = .dualStack
                }
            }
            rows.append(PortRow(type: t, localAddress: la, localPort: lp,
                                remoteAddress: ra, remotePort: rp, state: state))
        }

        for line in output.split(separator: "\n") {
            let prefix = line.first
            let value = String(line.dropFirst())
            switch prefix {
            case "f":
                commit()
                type = .unknown; name = nil; state = ""; inFile = true
            case "t":
                if value.contains("6") { type = .ipv6 }
                else if value.contains("4") { type = .ipv4 }
                else { type = .unknown }
            case "n":
                name = value
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default:
                break
            }
        }
        commit()
        return rows
    }

    private static func parseNameField(_ name: String) -> (String, Int?, String?, Int?) {
        let parts = name.components(separatedBy: "->")
        if parts.count == 2 {
            let (la, lp) = parseAddressAndPort(parts[0])
            let (ra, rp) = parseAddressAndPort(parts[1])
            return (la, lp, ra, rp)
        } else {
            let (la, lp) = parseAddressAndPort(name)
            return (la, lp, nil, nil)
        }
    }

    private static func parseAddressAndPort(_ s: String) -> (String, Int?) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let addr = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":") { return (addr, Int(rest.dropFirst())) }
            return (addr, nil)
        }
        if let colon = s.lastIndex(of: ":") {
            return (String(s[..<colon]), Int(s[s.index(after: colon)...]))
        }
        return (s, nil)
    }
}
