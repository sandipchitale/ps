import SwiftUI
import AppKit

// A freely-resizable inspector window for one process: full command, working
// directory, groups, environment and open TCP ports. Offers a single sudo
// escalation when details are unreadable because the process is owned by
// another user.
struct ProcessDetailWindow: View {
    let record: ProcRecord
    let monitor: ProcessMonitor

    @Environment(\.dismiss) private var dismiss

    enum DetailTab: String, CaseIterable, Identifiable {
        case command = "Command"
        case environment = "Environment"
        case ports = "TCP Ports"
        case systemProperties = "System Properties"
        var id: String { rawValue }
    }

    // Tabs to show for this process — System Properties only for JVM processes.
    private var tabs: [DetailTab] {
        DetailTab.allCases.filter { $0 != .systemProperties || record.isJava }
    }

    @State private var detail = ProcDetail()
    @State private var isLoading = true
    @State private var selectedTab: DetailTab = .command
    @State private var showingKillConfirm = false
    @State private var killError: String? = nil
    @State private var showingKillError = false

    // Text shown for the command/environment tabs and used for the Copy button.
    // (The TCP Ports tab renders a table; its copy text is `portsText`.)
    private var shownText: String {
        switch selectedTab {
        case .command:
            return detail.command.isEmpty ? "Command unavailable." : detail.command
        case .environment:
            return detail.environment.isEmpty
                ? "Environment unavailable — the process may have exited, or it belongs to another user. Use “Elevate (sudo)” to read it."
                : detail.environment.joined(separator: "\n")
        case .ports:
            return portsText
        case .systemProperties:
            return detail.systemProperties.isEmpty
                ? "System properties unavailable — jcmd could not attach to this JVM (it may have exited, declined the attach, or belong to another user)."
                : detail.systemProperties.joined(separator: "\n")
        }
    }

    private var portsText: String {
        guard !detail.ports.isEmpty else { return "" }
        return detail.ports.map { row in
            let local = "\(row.localAddress):\(row.localPort.map(String.init) ?? "*")"
            let remote = (row.remoteAddress != nil && row.remotePort != nil)
                ? " -> \(row.remoteAddress!):\(row.remotePort!)" : ""
            return "\(row.type.rawValue)\t\(local)\(remote)\t\(row.state)"
        }.joined(separator: "\n")
    }

    private var needsElevation: Bool {
        !detail.elevated && (detail.envDenied || detail.cwdDenied)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text("\(record.name)  ·  PID \(String(record.pid))")
                    .fontWeight(.semibold).lineLimit(1)
                if detail.elevated {
                    Label("elevated", systemImage: "lock.open.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }

            // Identity grid
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Parent PID").foregroundStyle(.secondary).font(.caption)
                    Text(String(record.ppid)).font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("User").foregroundStyle(.secondary).font(.caption)
                    Text("\(record.user) (uid \(record.uid))").font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Groups").foregroundStyle(.secondary).font(.caption)
                    Text(detail.groups.isEmpty ? (isLoading ? "…" : "—") : detail.groups.joined(separator: " "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                GridRow {
                    Text("Working dir").foregroundStyle(.secondary).font(.caption)
                    Text(detail.workingDirectory ?? (isLoading ? "…" : "unavailable"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            Divider()

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading process details…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Picker("", selection: $selectedTab) {
                    ForEach(tabs) { tab in
                        Text(tabLabel(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if selectedTab == .ports {
                    PortsTable(rows: detail.ports)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ScrollView(.vertical) {
                        Text(shownText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                HStack {
                    Button(role: .destructive) { showingKillConfirm = true } label: {
                        Label("Kill Process", systemImage: "xmark.octagon.fill")
                    }
                    .tint(.red)

                    if needsElevation {
                        Button { reload(elevate: true) } label: {
                            Label("Elevate (sudo)", systemImage: "lock.open")
                        }
                        .help("Authenticate to read this process owned by another user")
                    }

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shownText, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("\(record.name) (PID \(record.pid))")
        .task(id: record.pid) {
            if let t = monitor.pendingDetailTab[record.pid] { selectedTab = t }
            reload(elevate: false)
        }
        .onChange(of: monitor.pendingDetailTab[record.pid]) { _, newTab in
            // Re-focusing an already-open inspector (e.g. clicking the TCP badge)
            // switches it to the requested tab.
            if let t = newTab { selectedTab = t }
        }
        .alert("Terminate Process?", isPresented: $showingKillConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Normal Kill") { kill(useSudo: false) }
            Button("Sudo Kill (requires password)", role: .destructive) { kill(useSudo: true) }
        } message: {
            Text("Terminate '\(record.name)' (PID \(record.pid))?\n\nIf it belongs to the system or another user, Sudo Kill will request administrator privileges.")
        }
        .alert("Could Not Terminate Process", isPresented: $showingKillError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(killError ?? "")
        }
    }

    private func tabLabel(_ tab: DetailTab) -> String {
        switch tab {
        case .command: return "Command"
        case .environment: return detail.environment.isEmpty ? "Environment" : "Environment (\(detail.environment.count))"
        case .ports: return detail.ports.isEmpty ? "TCP Ports" : "TCP Ports (\(detail.ports.count))"
        case .systemProperties: return detail.systemProperties.isEmpty ? "System Properties" : "System Properties (\(detail.systemProperties.count))"
        }
    }

    private func reload(elevate: Bool) {
        isLoading = true
        Task {
            let d = await ProcessMonitor.fetchDetail(for: record, elevate: elevate)
            detail = d
            isLoading = false
        }
    }

    private func kill(useSudo: Bool) {
        Task {
            do {
                try await ProcessMonitor.performKill(pid: record.pid, useSudo: useSudo)
                monitor.refresh()
                dismiss()
            } catch {
                killError = error.localizedDescription
                showingKillError = true
            }
        }
    }
}

// Static, netstat-style table of a process's open TCP endpoints (no process
// columns, no filtering).
struct PortsTable: View {
    let rows: [PortRow]

    var body: some View {
        if rows.isEmpty {
            Text("No open TCP endpoints (or unavailable without privileges).")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            Table(rows) {
                TableColumn("TYPE") { (row: PortRow) in
                    PortTypeBadge(type: row.type)
                }
                .width(min: 60, ideal: 70, max: 90)

                TableColumn("LOCAL ADDRESS") { (row: PortRow) in
                    Text(row.localAddress)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 100, ideal: 170, max: 320)

                TableColumn("PORT") { (row: PortRow) in
                    Text(row.localPort.map(String.init) ?? "*")
                        .font(.system(.subheadline, design: .monospaced)).fontWeight(.semibold)
                }
                .width(min: 45, ideal: 55, max: 80)

                TableColumn("REMOTE ADDRESS") { (row: PortRow) in
                    Text(row.remoteAddress ?? "-")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 100, ideal: 170, max: 320)

                TableColumn("PORT") { (row: PortRow) in
                    Text(row.remotePort.map(String.init) ?? "-")
                        .font(.system(.subheadline, design: .monospaced)).fontWeight(.semibold)
                }
                .width(min: 45, ideal: 55, max: 80)

                TableColumn("STATE") { (row: PortRow) in
                    PortStateBadge(state: row.state)
                }
                .width(min: 80, ideal: 110, max: 150)
            }
            .tableStyle(.inset)
        }
    }
}

struct PortTypeBadge: View {
    let type: PortRow.PortType

    private var color: Color {
        switch type {
        case .ipv4: return .blue
        case .ipv6: return .purple
        case .dualStack: return .green
        case .unknown: return .gray
        }
    }

    var body: some View {
        Text(type.rawValue)
            .font(.caption).fontWeight(.bold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(4)
    }
}

struct PortStateBadge: View {
    let state: String

    private var color: Color {
        switch state.uppercased() {
        case "LISTEN": return .blue
        case "ESTABLISHED": return .green
        case "CLOSE_WAIT", "TIME_WAIT": return .orange
        case "SYN_SENT", "SYN_RCVD", "SYN_RECEIVED": return .teal
        case "FIN_WAIT_1", "FIN_WAIT_2", "CLOSING", "LAST_ACK": return .red
        case "CLOSED": return .gray
        case "": return .secondary
        default: return .secondary
        }
    }

    var body: some View {
        Text(state.isEmpty ? "—" : state)
            .font(.caption).fontWeight(.bold)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3), lineWidth: 1))
    }
}
