import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ProcessMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Single shared monitor so the inspector windows can refresh the main table.
    @State private var monitor = ProcessMonitor()

    var body: some Scene {
        Window("Process Monitor", id: "main") {
            ContentView(monitor: monitor)
                .frame(minWidth: 1100, idealWidth: 1500, minHeight: 700, idealHeight: 900)
        }
        .windowStyle(.titleBar)

        // Auxiliary, freely-resizable process inspector window.
        WindowGroup("Process", id: "process-info", for: ProcRecord.self) { $record in
            if let record {
                ProcessDetailWindow(record: record, monitor: monitor)
            }
        }
        .defaultSize(width: 900, height: 640)
    }
}
