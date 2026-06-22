# Process Monitor (ps)

A native macOS application built with SwiftUI that lists running processes with
their identity, full command line, working directory, environment, groups and
open TCP ports — viewable as a flat table or a fully-expanded process tree.

It is a sibling of the [TCP Port Monitor (netstat)](../netstat/README.md) app and
shares its titlebar-integrated controls, resizable columns, and inspector-window
design.

---

## Key Features

1. **Process Listing**: PID, Parent PID, user, %CPU, %MEM, state (`STAT`), open
   TCP endpoint count, and the full command line for every process (`ps -axww`).
2. **Table or Process Tree**:
   - **Table** view — a sortable, resizable native table.
   - **Tree** view — the parent/child hierarchy, rendered **fully expanded** (a
     DFS-flattened list with depth indentation), so every descendant is visible
     at once. Ancestors of matching processes are kept as connective tissue when
     filtering.
3. **Parent PID hyperlink**: The `PARENT` column is a link — click it to jump to
   and select the parent process (switching to the table view so the row is
   visible).
4. **Process Inspector**: Click the **(i)** next to a command to open a resizable
   window for that process showing:
   - the **full command line** (`ps -ww -o command=`), wrapped and selectable;
   - **identity** — parent PID, user/uid, and **groups** (`id -Gn`);
   - the **working directory** (`lsof -d cwd`);
   - the **environment** — a sorted `KEY=value` list read via the
     `KERN_PROCARGS2` sysctl (the same source `ps` uses);
   - the **open TCP ports** for the process (`lsof -iTCP`);
   - a **Kill Process** button, and an **Elevate (sudo)** button when details
     are unreadable because the process belongs to another user.
5. **Ellipsized cells**: Long command lines are truncated with a tail ellipsis;
   the full value is available via the inspector window (and a hover tooltip).
6. **Filtering & Search**:
   - **My processes / All**: starts filtered to your own processes; toggle
     **Mine** off to see every process.
   - **Search**: matches command line, user, PID and parent PID. Enable **Deep
     search** to also match **working directory** and **environment** (these are
     fetched and cached in the background for the listed processes).
7. **Privilege escalation (once)**: For a process you don't own, the inspector's
   **Elevate (sudo)** button issues a *single* administrator-authenticated shell
   script (via the standard macOS authorization dialog) that gathers the command,
   working directory, environment and ports in one prompt.
8. **Kill Process**: From the row action button, the right-click context menu, or
   the inspector — with **Normal Kill** and **Sudo Kill** (authenticates via the
   standard macOS system authorization dialog). The list refreshes immediately.
9. **Titlebar controls**: view-mode toggle, Mine/Deep-search toggles, auto-refresh
   clock + interval menu + manual refresh, and a Light/Dark/System theme selector.

---

## Build & Install

The `Process Monitor.app` bundle is a **build artifact** and is not committed to
git — it is recreated from source by `build-app.sh`. The bundle's inputs
(`Info.plist`, and an optional `AppIcon.icns`) live in `packaging/`.

```bash
# Build the release binary and assemble "./Process Monitor.app"
./build-app.sh

# Build, then copy the bundle into /Applications
./build-app.sh --install

# Build, install, and (re)launch the app
./build-app.sh --install --run
```

To install manually instead, drag the freshly built `Process Monitor.app` into
your **Applications** folder, then launch **Process Monitor** from Launchpad or
Spotlight.

### Project layout
- `Sources/` — Swift source (compiled by SwiftPM; see `Package.swift`).
- `packaging/` — app bundle inputs: `Info.plist` (and optional `AppIcon.icns`).
- `build-app.sh` — compiles the binary and assembles `Process Monitor.app`.
- `Process Monitor.app/` — generated bundle (git-ignored).

---

## Code Architecture

- **`Sources/ProcRecord.swift`**: `ProcRecord` models one process row
  (`Codable`/`Hashable` so it can be passed as a window value); `ProcNode` wraps a
  record with a tree `depth` for the flattened tree view.
- **`Sources/ProcessMonitor.swift`**: `@Observable` controller. Runs `ps` to list
  processes and a global `lsof` pass for per-PID TCP counts, builds the filtered
  flat and tree (DFS-flattened) row sets, drives auto-refresh, enriches rows with
  cwd/env for deep search, fetches per-process detail (command, cwd, env, groups,
  ports), performs the one-shot sudo escalation, and kills processes.
- **`Sources/ContentView.swift`**: The main GUI — titlebar layout, search bar,
  status bar — plus `ProcessTable` (the flat/tree native table) and the row cells
  (`PPIDCell`, `CommandCell`, `PortsBadge`).
- **`Sources/ProcessDetailWindow.swift`**: The resizable per-process inspector
  window (command / environment / TCP-ports tabs, identity grid, kill + elevate).
- **`Sources/ProcessMonitorApp.swift`**: App scenes — the main window and the
  resizable inspector `WindowGroup` — sharing one `ProcessMonitor`.
