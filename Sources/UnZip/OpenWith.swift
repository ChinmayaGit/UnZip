import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum OpenWith {
    struct App: Identifiable, Hashable {
        var url: URL
        var name: String
        var isDefault: Bool
        var id: String { url.standardizedFileURL.path }
    }

    static func apps(for file: URL) -> [App] {
        let workspace = NSWorkspace.shared
        let target = file.standardizedFileURL
        let defaultApp = workspace.urlForApplication(toOpen: target)?.standardizedFileURL
        var seen = Set<String>()
        var urls: [URL] = []

        for url in workspace.urlsForApplications(toOpen: target) + extraApps(for: target) {
            let path = url.standardizedFileURL
            let key = Bundle(url: path)?.bundleIdentifier ?? path.path
            guard seen.insert(key).inserted else { continue }
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            guard isUsableApp(path) else { continue }
            urls.append(path)
        }

        let preferred = preferredNames(for: target)
        return urls
            .map { App(url: $0, name: displayName(for: $0), isDefault: $0 == defaultApp) }
            .sorted { lhs, rhs in
                let left = rank(lhs, preferred: preferred)
                let right = rank(rhs, preferred: preferred)
                if left != right { return left < right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func contentType(for file: URL) -> UTType? {
        if let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        if FormatDetector.isDirectory(file) {
            return .folder
        }
        return UTType(filenameExtension: file.pathExtension)
    }

    static func defaultApp(for file: URL) -> App? {
        apps(for: file).first(where: \.isDefault)
    }

    static func open(_ files: [URL], with application: URL) {
        NSWorkspace.shared.open(files, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    static func setDefault(_ application: URL, for file: URL, completion: @escaping @Sendable (String?) -> Void) {
        guard let type = contentType(for: file) else {
            completion("Couldn’t determine this file type.")
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type) { error in
            completion(error?.localizedDescription)
        }
    }

    @MainActor
    static func chooseOther(for files: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an application to open this file."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(files, with: app)
    }

    private static func extraApps(for file: URL) -> [URL] {
        preferredNames(for: file).compactMap(locateApp)
    }

    private static func preferredNames(for file: URL) -> [String] {
        if MediaKind.isVideo(file) {
            return ["VLC", "QuickTime Player", "IINA", "Elmedia Player", "Infuse"]
        }
        if MediaKind.isAudio(file) {
            return ["VLC", "Music", "QuickTime Player", "IINA"]
        }
        if FolderCover.isImage(file) {
            return ["Preview", "Photos"]
        }
        if FormatDetector.isUnzippable(file) {
            return ["The Unarchiver", "Keka", "Archive Utility"]
        }
        if FormatDetector.isDirectory(file) {
            return ["Finder", "Terminal", "Visual Studio Code", "Cursor"]
        }
        return ["Preview", "TextEdit"]
    }

    private static func locateApp(_ name: String) -> URL? {
        let paths = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "/System/Applications/Utilities/\(name).app",
            "/System/Library/CoreServices/\(name).app",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/\(name).app").path
        ]
        return paths.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func displayName(for url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    private static func isUsableApp(_ url: URL) -> Bool {
        let name = displayName(for: url)
        let blocked = ["Helper", "Uninstaller", "Updater", "Crash Reporter"]
        return !blocked.contains { name.localizedCaseInsensitiveContains($0) }
    }

    private static func rank(_ app: App, preferred: [String]) -> Int {
        if app.isDefault { return 0 }
        if let index = preferred.firstIndex(where: { app.name.localizedCaseInsensitiveContains($0) }) {
            return 1 + index
        }
        return 100
    }
}

struct OpenWithMenu: View {
    @EnvironmentObject private var state: AppState
    let urls: [URL]

    var body: some View {
        let apps = urls.first.map(OpenWith.apps(for:)) ?? []
        Menu("Open With") {
            if apps.isEmpty {
                Button("No applications found") {}
                    .disabled(true)
            } else {
                ForEach(apps.prefix(14)) { app in
                    Button(app.isDefault ? "\(app.name) (default)" : app.name) {
                        state.openFiles(urls, with: app.url)
                    }
                }
            }
            Divider()
            Button("Other…") {
                OpenWith.chooseOther(for: urls)
            }
            if let file = urls.first, !apps.isEmpty {
                Divider()
                Menu("Set as Default") {
                    ForEach(apps.prefix(14)) { app in
                        Button(app.isDefault ? "✓ \(app.name)" : app.name) {
                            state.setDefaultOpenWith(app.url, for: file)
                        }
                    }
                }
            }
        }
    }
}
