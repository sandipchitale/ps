import SwiftUI

struct ContentView: View {
    @Bindable var monitor: ProcessMonitor
    @State private var selectedTheme: Theme = .system

    enum Theme: String, CaseIterable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        var id: String { rawValue }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
        var icon: String {
            switch self {
            case .system: return "laptopcomputer"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            DetailView(monitor: monitor)
                .navigationTitle("Process Monitor")
                .preferredColorScheme(selectedTheme.colorScheme)
                .toolbar {
                    ToolbarItemGroup(placement: .principal) {
                        HStack(spacing: 12) {
                            Picker("View", selection: $monitor.viewMode) {
                                Image(systemName: "tablecells").tag(ProcessMonitor.ViewMode.table)
                                Image(systemName: "list.bullet.indent").tag(ProcessMonitor.ViewMode.tree)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .help("Table or Process Tree")

                            Divider().frame(height: 16)

                            ControlGroup {
                                Toggle("Mine", isOn: $monitor.showMyProcessesOnly)
                                Toggle("Deep search", isOn: $monitor.deepSearch)
                            }
                            .help("Show only my processes · Deep search includes cwd & env")
                        }
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Toggle(isOn: $monitor.isAutoRefreshEnabled) {
                                    Image(systemName: "clock")
                                }
                                .toggleStyle(.button)
                                .help("Auto Refresh")

                                Picker("Interval", selection: $monitor.refreshInterval) {
                                    Text("1s").tag(1.0)
                                    Text("2s").tag(2.0)
                                    Text("5s").tag(5.0)
                                    Text("10s").tag(10.0)
                                    Text("30s").tag(30.0)
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .disabled(!monitor.isAutoRefreshEnabled)
                                .frame(width: 65)

                                Button(action: { monitor.refresh() }) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .disabled(monitor.isRefreshing)
                                .help("Refresh Now")
                            }

                            Divider().frame(height: 16)

                            Picker("Theme", selection: $selectedTheme) {
                                ForEach(Theme.allCases) { theme in
                                    Image(systemName: theme.icon).tag(theme)
                                }
                            }
                            .pickerStyle(.segmented)
                            .help("Select Theme")
                        }
                    }
                }
        }
    }
}

struct DetailView: View {
    @Bindable var monitor: ProcessMonitor

    @State private var selectedPID: ProcNode.ID? = nil
    @State private var killStatus: String? = nil
    @State private var showingStatus = false
    @State private var pendingKill: ProcRecord? = nil
    @State private var showingKillConfirm = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(monitor.deepSearch ? "Search command, cwd, env, user, PID…"
                                             : "Search command, user, PID… (enable Deep search for cwd/env)",
                          text: $monitor.searchText)
                    .textFieldStyle(.plain)
                if !monitor.searchText.isEmpty {
                    Button(action: { monitor.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            .padding()
            .background(.thinMaterial)

            ProcessTable(
                monitor: monitor,
                selectedPID: $selectedPID,
                onInfo: { showInfo(for: $0) },
                onPorts: { showInfo(for: $0, tab: .ports) },
                onSelectParent: { selectParent($0) },
                onKillRequest: { pendingKill = $0; showingKillConfirm = true },
                onKill: { kill($0, useSudo: $1) }
            )

            // Status bar
            HStack {
                HStack(spacing: 8) {
                    if let err = monitor.lastError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(err).font(.caption).foregroundStyle(.red)
                    } else {
                        Circle().fill(monitor.isAutoRefreshEnabled ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(monitor.showMyProcessesOnly ? "Showing my processes" : "Showing all processes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(monitor.filteredRecords.count) of \(monitor.records.count) processes")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let d = monitor.lastRefreshedDate {
                    Text("Updated: \(timeString(d))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .trailing)
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
            .background(.thinMaterial)
        }
        .frame(minWidth: 980)
        .alert("Terminate Process?", isPresented: $showingKillConfirm, presenting: pendingKill) { rec in
            Button("Cancel", role: .cancel) { }
            Button("Normal Kill") { kill(rec, useSudo: false) }
            Button("Sudo Kill (requires password)", role: .destructive) { kill(rec, useSudo: true) }
        } message: { rec in
            Text("Terminate '\(rec.name)' (PID \(rec.pid), user \(rec.user))?\n\nIf it belongs to the system or another user, Sudo Kill will request administrator privileges.")
        }
        .alert("Process Management", isPresented: $showingStatus) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(killStatus ?? "")
        }
        .onChange(of: monitor.records) { _, newRecords in
            if let pid = selectedPID, !newRecords.contains(where: { $0.pid == pid }) {
                selectedPID = nil
            }
        }
    }

    private func selectParent(_ ppid: Int) {
        // The link is only active when the parent is visible in the current view
        // (table or tree), so just select it without changing the view mode.
        selectedPID = ppid
    }

    private func showInfo(for rec: ProcRecord, tab: ProcessDetailWindow.DetailTab = .command) {
        monitor.pendingDetailTab[rec.pid] = tab
        openWindow(id: "process-info", value: rec)
    }

    private func kill(_ rec: ProcRecord, useSudo: Bool) {
        Task {
            do {
                try await monitor.killProcess(pid: rec.pid, useSudo: useSudo)
                killStatus = "Sent termination signal to '\(rec.name)' (PID \(rec.pid))."
            } catch {
                killStatus = "Failed to terminate process:\n\(error.localizedDescription)"
            }
            showingStatus = true
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .medium
        return f.string(from: date)
    }
}

// The process table / tree. Isolated into its own View so the column builders
// type-check quickly and the two Table variants (sortable flat vs. pre-ordered
// fully-expanded tree) don't bloat the parent body.
struct ProcessTable: View {
    @Bindable var monitor: ProcessMonitor
    @Binding var selectedPID: ProcNode.ID?
    let onInfo: (ProcRecord) -> Void
    let onPorts: (ProcRecord) -> Void
    let onSelectParent: (Int) -> Void
    let onKillRequest: (ProcRecord) -> Void
    let onKill: (ProcRecord, Bool) -> Void

    var body: some View {
        let rows = monitor.viewMode == .tree ? monitor.treeFlatNodes : monitor.flatNodes
        // The parent link is active only when the parent row is actually visible
        // among the currently displayed rows (so jumping can select it).
        let visiblePIDs = Set(rows.map(\.pid))

        let colPID = TableColumn("PID", value: \ProcNode.pid) { (node: ProcNode) in
            PIDCell(pid: node.pid, depth: node.depth)
        }
        .width(min: 60, ideal: 90, max: 240)

        let colPPID = TableColumn("PARENT", value: \ProcNode.ppid) { (node: ProcNode) in
            PPIDCell(ppid: node.ppid, isPresent: visiblePIDs.contains(node.ppid)) {
                onSelectParent(node.ppid)
            }
        }
        .width(min: 60, ideal: 70, max: 100)

        let colUser = TableColumn("USER", value: \ProcNode.user) { (node: ProcNode) in
            Text(node.user).font(.subheadline).lineLimit(1)
        }
        .width(min: 60, ideal: 80, max: 140)

        let colCPU = TableColumn("CPU%", value: \ProcNode.cpu) { (node: ProcNode) in
            Text(String(format: "%.1f", node.cpu))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(node.cpu > 20 ? .orange : .secondary)
        }
        .width(min: 45, ideal: 50, max: 70)

        let colMem = TableColumn("MEM%", value: \ProcNode.mem) { (node: ProcNode) in
            Text(String(format: "%.1f", node.mem))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .width(min: 45, ideal: 50, max: 70)

        let colStat = TableColumn("STAT", value: \ProcNode.stat) { (node: ProcNode) in
            Text(node.stat).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
        .width(min: 45, ideal: 55, max: 80)

        let colJava = TableColumn("Java", value: \ProcNode.javaSortValue) { (node: ProcNode) in
            JavaBadge(isJava: node.isJava)
        }
        .width(min: 36, ideal: 42, max: 52)

        let colPorts = TableColumn("TCP", value: \ProcNode.portCount) { (node: ProcNode) in
            PortsBadge(count: node.portCount) { onPorts(node.record) }
        }
        .width(min: 40, ideal: 50, max: 70)

        let colCommand = TableColumn("COMMAND", value: \ProcNode.command) { (node: ProcNode) in
            CommandCell(command: node.command) { onInfo(node.record) }
        }
        .width(min: 220, ideal: 420)

        let colActions = TableColumn("") { (node: ProcNode) in
            Button(action: { onKillRequest(node.record) }) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Terminate \(node.record.name) (PID \(node.pid))")
        }
        .width(min: 32, ideal: 36, max: 44)

        return Group {
            if rows.isEmpty {
                VStack(spacing: 15) {
                    Spacer()
                    Image(systemName: "cpu").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(monitor.isRefreshing ? "Reading processes…" : "No processes match the filters.")
                        .font(.headline).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if monitor.viewMode == .tree {
                // Empty, constant sort order keeps the pre-built DFS tree order.
                Table(rows, selection: $selectedPID, sortOrder: .constant([KeyPathComparator<ProcNode>]())) {
                    colPID; colPPID; colUser; colCPU; colMem; colStat; colJava; colPorts; colCommand; colActions
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: ProcNode.ID.self) { contextMenu($0) }
            } else {
                Table(rows, selection: $selectedPID, sortOrder: $monitor.sortOrder) {
                    colPID; colPPID; colUser; colCPU; colMem; colStat; colJava; colPorts; colCommand; colActions
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: ProcNode.ID.self) { contextMenu($0) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ selection: Set<ProcNode.ID>) -> some View {
        if let pid = selection.first, let rec = monitor.records.first(where: { $0.pid == pid }) {
            Button("Inspect…") { onInfo(rec) }
            Divider()
            Button("Kill Process (Normal)") { onKill(rec, false) }
            Button("Kill Process with Sudo") { onKill(rec, true) }
        }
    }
}

// Marks JVM processes with a coffee-cup glyph (Java's emblem) in the Java column.
struct JavaBadge: View {
    let isJava: Bool
    var body: some View {
        if isJava {
            Image(systemName: "cup.and.saucer.fill")
                .foregroundStyle(.brown)
                .help("Java process — see the System Properties tab in its inspector")
                .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
    }
}

struct PortsBadge: View {
    let count: Int
    var onTap: (() -> Void)? = nil

    var body: some View {
        if count > 0 {
            Button(action: { onTap?() }) {
                Text("\(count)")
                    .font(.caption).fontWeight(.bold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Show this process's open TCP ports")
        } else {
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// PPID rendered as a hyperlink-style button that selects the parent row.
struct PPIDCell: View {
    let ppid: Int
    let isPresent: Bool
    let onTap: () -> Void

    var body: some View {
        if isPresent {
            Button(action: onTap) {
                Text(String(ppid))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.blue)
                    .underline()
            }
            .buttonStyle(.plain)
            .help("Jump to parent process \(ppid)")
        } else {
            Text(String(ppid))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// PID, indented by tree depth in tree mode to show the process hierarchy.
struct PIDCell: View {
    let pid: Int
    var depth: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            if depth > 0 {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
                    .padding(.leading, CGFloat(depth) * 12 - 6)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(String(pid))
                .font(.system(.subheadline, design: .monospaced))
                .fontWeight(.semibold)
        }
    }
}

// Ellipsized command with an (i) button to open the full inspector window.
struct CommandCell: View {
    let command: String
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(command)
            Spacer(minLength: 0)
            Button(action: onInfo) {
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Show full command, working directory, environment and TCP ports")
        }
    }
}
