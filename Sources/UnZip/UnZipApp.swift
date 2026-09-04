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
                        state.receiveDropped(urls)
                    }
                    NSApp.servicesProvider = appDelegate
                    NSUpdateDynamicServices()
                    appDelegate.flushPending()
                }
                .onOpenURL { url in
                    state.receiveDropped([url])
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
            CommandMenu("View") {
                Button("as Details") { state.setLayout(.details) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("as Grid") { state.setLayout(.grid) }
                    .keyboardShortcut("1", modifiers: .command)
                Divider()
                Button(state.showPreviewPane ? "Hide Preview" : "Show Preview") {
                    state.togglePreviewPane()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Button("Sort by Name") { state.setSort(.name) }
                Button("Sort by Date") { state.setSort(.date) }
                Button("Sort by Type") { state.setSort(.type) }
                Button("Sort by Size") { state.setSort(.size) }
            }
            CommandMenu("Go") {
                Button("Back") { state.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!(state.selectedDocument?.canGoBack ?? false))
                Button("Forward") { state.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!(state.selectedDocument?.canGoForward ?? false))
                Button("Enclosing Folder") { state.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!(state.selectedDocument?.canGoUp ?? false))
                Divider()
                Button("Reveal Archive in Finder") {
                    if let url = state.selectedDocument?.localURL {
                        ArchiveEngine.reveal(url)
                    }
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpen: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--extract-test"),
           CommandLine.arguments.count >= 5 {
            let archive = URL(fileURLWithPath: CommandLine.arguments[2])
            let dest = URL(fileURLWithPath: CommandLine.arguments[3])
            let name = CommandLine.arguments[4]
            do {
                let opened = try ArchiveEngine.open(url: archive)
                guard let entry = opened.entries.first(where: { $0.name == name || $0.path == name || $0.path.hasSuffix("/\(name)") }) else {
                    fputs("Missing \(name)\n", stderr)
                    exit(1)
                }
                let payload = ArchiveDragPayload.make(
                    archiveURL: archive,
                    format: opened.format,
                    password: nil,
                    roots: [entry],
                    allEntries: opened.entries
                )
                try payload.write(to: dest.appendingPathComponent(payload.suggestedName))
                FileHandle.standardOutput.write(Data("extracted \(payload.suggestedName)\n".utf8))
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--list"),
           let path = CommandLine.arguments.drop(while: { $0 != "--list" }).dropFirst().first {
            do {
                let opened = try ArchiveEngine.open(url: URL(fileURLWithPath: path))
                let extra = opened.parts > 1 ? " (\(opened.parts) parts)" : ""
                FileHandle.standardOutput.write(Data("\(opened.format.displayName)\(extra)\n".utf8))
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
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        deliver(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        deliver([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        deliver(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    @objc func zipWithUnZip(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        deliver(urls(from: pboard))
    }

    func flushPending() {
        let urls = pendingURLs
        pendingURLs.removeAll()
        if !urls.isEmpty {
            onOpen?(urls)
        }
    }

    private func deliver(_ urls: [URL]) {
        let unique = Array(Set(urls.map { $0.standardizedFileURL }))
        guard !unique.isEmpty else { return }
        if let onOpen {
            onOpen(unique)
        } else {
            pendingURLs.append(contentsOf: unique)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func urls(from pboard: NSPasteboard) -> [URL] {
        if let items = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return items
        }
        if let paths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
