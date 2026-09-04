import AppKit
import SwiftUI

@main
struct UnZipApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    appDelegate.onOpen = { urls in
                        for url in urls { state.open(url: url) }
                    }
                }
                .onOpenURL { url in
                    state.open(url: url)
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Archive…") { state.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Connect to Server…") { state.showFTPSheet = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Create ZIP…") { state.showCreateSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Extract…") { state.extractSelected() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(state.selectedDocument == nil)
            }
            CommandMenu("Go") {
                Button("Enclosing Folder") {
                    if let url = state.selectedDocument?.localURL {
                        ArchiveEngine.reveal(url)
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpen: (([URL]) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--list"),
           let path = CommandLine.arguments.drop(while: { $0 != "--list" }).dropFirst().first {
            do {
                let opened = try ArchiveEngine.open(url: URL(fileURLWithPath: path))
                FileHandle.standardOutput.write(Data("\(opened.format.displayName)\n".utf8))
                for entry in opened.entries.sorted(by: { $0.path < $1.path }) {
                    let mark = entry.isDirectory ? "/" : ""
                    FileHandle.standardOutput.write(Data("\(entry.path)\(mark)\n".utf8))
                }
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        onOpen?(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
