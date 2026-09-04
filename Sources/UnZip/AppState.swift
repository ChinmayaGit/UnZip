import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var documents: [OpenDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published var ftpSessions: [FTPSession] = []
    @Published var selectedFTPID: UUID?
    @Published var bookmarks: [FTPBookmark] = []
    @Published var recents: [URL] = []
    @Published var status: String = "Drop an archive or connect to a server."
    @Published var progress: Double?
    @Published var busyMessage: String?
    @Published var alertMessage: String?
    @Published var showFTPSheet = false
    @Published var showCreateSheet = false
    @Published var showExtractSheet = false
    @Published var passwordPrompt: PasswordPrompt?
    @Published var preview: PreviewContent?

    private let defaults = UserDefaults.standard
    private let recentsKey = "unzip.recents"
    private let bookmarksKey = "unzip.bookmarks"

    init() {
        recents = (defaults.stringArray(forKey: recentsKey) ?? []).prefix(12).compactMap {
            let url = URL(fileURLWithPath: $0)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let data = defaults.data(forKey: bookmarksKey),
           let saved = try? JSONDecoder().decode([FTPBookmark].self, from: data) {
            bookmarks = saved
        }
    }

    var selectedDocument: OpenDocument? {
        documents.first(where: { $0.id == selectedDocumentID })
    }

    var selectedFTP: FTPSession? {
        ftpSessions.first(where: { $0.id == selectedFTPID })
    }

    var capabilities: String {
        var parts = ["ZIP", "TAR", "GZ", "ISO", "DMG"]
        if Toolchain.rarReady { parts.append("RAR") }
        if Toolchain.sevenReady { parts.append("7Z") }
        if Toolchain.unar != nil { parts.append("CAB/LHA") }
        return parts.joined(separator: " · ")
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.archiveTypes
        panel.title = "Open Archive"
        if panel.runModal() == .OK {
            for url in panel.urls {
                open(url: url)
            }
        }
    }

    func open(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        busyMessage = "Reading \(url.lastPathComponent)…"
        status = busyMessage ?? ""
        Task.detached { [weak self] in
            do {
                let opened = try ArchiveEngine.open(url: url)
                await MainActor.run {
                    guard let self else { return }
                    let doc = OpenDocument(
                        title: url.lastPathComponent,
                        format: opened.format,
                        source: .file(url),
                        localURL: url
                    )
                    doc.entries = opened.entries
                    self.documents.append(doc)
                    self.selectedDocumentID = doc.id
                    self.selectedFTPID = nil
                    self.remember(url)
                    self.busyMessage = nil
                    self.status = "\(opened.entries.count) items · \(opened.format.displayName)"
                    self.preview = nil
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                    self?.status = "Could not open archive."
                    if let zipError = error as? UnZipError, case .passwordRequired = zipError {
                        self?.passwordPrompt = PasswordPrompt(url: url)
                    }
                }
            }
        }
    }

    func openWithPassword(_ password: String, url: URL) {
        passwordPrompt = nil
        busyMessage = "Unlocking…"
        Task.detached { [weak self] in
            do {
                let format = FormatDetector.detect(url: url)
                let entries = try ArchiveEngine.list(url: url, format: format)
                await MainActor.run {
                    guard let self else { return }
                    let doc = OpenDocument(title: url.lastPathComponent, format: format, source: .file(url), localURL: url)
                    doc.entries = entries
                    doc.password = password
                    self.documents.append(doc)
                    self.selectedDocumentID = doc.id
                    self.busyMessage = nil
                    self.status = "Unlocked · \(entries.count) items"
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func close(_ document: OpenDocument) {
        documents.removeAll { $0.id == document.id }
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.last?.id
            preview = nil
        }
    }

    func extractSelected(to destination: URL? = nil) {
        guard let document = selectedDocument, let url = document.localURL else { return }
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.title = "Extract To"
            panel.prompt = "Extract"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            dest = chosen
        }
        let entries = document.selectedEntries.isEmpty ? nil : document.selectedEntries
        let format = document.format
        let password = document.password
        busyMessage = "Extracting…"
        progress = 0.15
        Task.detached { [weak self] in
            do {
                try ArchiveEngine.extract(url: url, format: format, destination: dest, entries: entries, password: password)
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.progress = nil
                    self?.status = "Extracted to \(dest.lastPathComponent)"
                    ArchiveEngine.openInFinder(dest)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.progress = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func previewEntry(_ entry: ArchiveEntry) {
        guard let document = selectedDocument, let url = document.localURL else { return }
        if entry.isDirectory {
            document.currentPath = entry.path
            document.selectedIDs = []
            preview = nil
            return
        }
        busyMessage = "Loading preview…"
        let format = document.format
        let password = document.password
        Task.detached { [weak self] in
            do {
                let data = try ArchiveEngine.extractData(url: url, format: format, path: entry.path, password: password)
                let content = PreviewContent.make(name: entry.name, data: data)
                await MainActor.run {
                    self?.preview = content
                    self?.busyMessage = nil
                    self?.status = entry.path
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func createArchive(from sources: [URL], to destination: URL) {
        busyMessage = "Creating archive…"
        Task.detached { [weak self] in
            do {
                try ArchiveWriter.createZip(from: sources, to: destination)
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.status = "Created \(destination.lastPathComponent)"
                    self?.open(url: destination)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func connectFTP(_ bookmark: FTPBookmark, password: String) {
        let session = FTPSession(bookmark: bookmark)
        ftpSessions.append(session)
        selectedFTPID = session.id
        selectedDocumentID = nil
        busyMessage = "Connecting to \(bookmark.host)…"
        Task.detached { [weak self] in
            do {
                if bookmark.protocolKind == .sftp {
                    let items = try SFTPClient.list(host: bookmark.host, port: bookmark.port, username: bookmark.username, path: bookmark.remotePath)
                    await MainActor.run {
                        session.items = items.map(RemoteListingItem.init)
                        session.currentPath = bookmark.remotePath
                        session.isConnected = true
                        self?.busyMessage = nil
                        self?.status = "SFTP \(bookmark.host)"
                    }
                } else {
                    let client = FTPClient()
                    try client.connect(
                        host: bookmark.host,
                        port: UInt16(bookmark.port),
                        username: bookmark.username,
                        password: password,
                        useTLS: bookmark.protocolKind == .ftps || bookmark.useTLS
                    )
                    if bookmark.remotePath != "/" && !bookmark.remotePath.isEmpty {
                        try? client.cwd(bookmark.remotePath)
                    }
                    let items = try client.list()
                    await MainActor.run {
                        session.client = client
                        session.items = items.map(RemoteListingItem.init)
                        session.currentPath = client.currentPath
                        session.isConnected = true
                        session.password = password
                        self?.busyMessage = nil
                        self?.status = "FTP \(bookmark.host)\(client.currentPath)"
                    }
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                    self?.ftpSessions.removeAll { $0.id == session.id }
                }
            }
        }
        saveBookmark(bookmark)
    }

    func ftpOpen(_ item: RemoteListingItem) {
        guard let session = selectedFTP else { return }
        if item.isDirectory {
            browseFTP(session, path: session.joined(item.name))
        } else {
            downloadAndOpen(item, session: session)
        }
    }

    func ftpUp() {
        guard let session = selectedFTP else { return }
        var parts = session.currentPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        parts.removeLast()
        let next = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        browseFTP(session, path: next)
    }

    func browseFTP(_ session: FTPSession, path: String) {
        busyMessage = "Listing…"
        let bookmark = session.bookmark
        let client = session.client
        Task.detached { [weak self] in
            do {
                let items: [FTPListItem]
                if bookmark.protocolKind == .sftp {
                    items = try SFTPClient.list(host: bookmark.host, port: bookmark.port, username: bookmark.username, path: path)
                } else if let client {
                    try client.cwd(path)
                    items = try client.list()
                } else {
                    throw UnZipError.notConnected
                }
                await MainActor.run {
                    session.currentPath = path
                    session.items = items.map(RemoteListingItem.init)
                    self?.busyMessage = nil
                    self?.status = "\(session.bookmark.host)\(path)"
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func downloadAndOpen(_ item: RemoteListingItem, session: FTPSession) {
        let remote = session.joined(item.name)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(item.name)
        busyMessage = "Downloading \(item.name)…"
        progress = 0.2
        let bookmark = session.bookmark
        let client = session.client
        Task.detached { [weak self] in
            do {
                if bookmark.protocolKind == .sftp {
                    try SFTPClient.download(host: bookmark.host, port: bookmark.port, username: bookmark.username, remote: remote, local: local)
                } else if let client {
                    try client.download(path: remote, to: local)
                } else {
                    throw UnZipError.notConnected
                }
                await MainActor.run {
                    self?.progress = nil
                    self?.busyMessage = nil
                    self?.open(url: local)
                }
            } catch {
                await MainActor.run {
                    self?.progress = nil
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func uploadToFTP(local: URL) {
        guard let session = selectedFTP else { return }
        let remote = session.joined(local.lastPathComponent)
        busyMessage = "Uploading \(local.lastPathComponent)…"
        let bookmark = session.bookmark
        let client = session.client
        Task.detached { [weak self] in
            do {
                if bookmark.protocolKind == .sftp {
                    try SFTPClient.upload(host: bookmark.host, port: bookmark.port, username: bookmark.username, local: local, remote: remote)
                } else if let client {
                    try client.upload(local: local, remoteName: remote)
                } else {
                    throw UnZipError.notConnected
                }
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.status = "Uploaded \(local.lastPathComponent)"
                    self?.refreshFTP(session)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshFTP(_ session: FTPSession) {
        let path = session.currentPath
        let bookmark = session.bookmark
        let client = session.client
        Task.detached {
            do {
                let items: [FTPListItem]
                if bookmark.protocolKind == .sftp {
                    items = try SFTPClient.list(host: bookmark.host, port: bookmark.port, username: bookmark.username, path: path)
                } else if let client {
                    items = try client.list()
                } else {
                    return
                }
                await MainActor.run {
                    session.items = items.map(RemoteListingItem.init)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func disconnectFTP(_ session: FTPSession) {
        session.client?.disconnect()
        ftpSessions.removeAll { $0.id == session.id }
        if selectedFTPID == session.id {
            selectedFTPID = ftpSessions.last?.id
        }
        status = "Disconnected."
    }

    func saveBookmark(_ bookmark: FTPBookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else if !bookmarks.contains(where: { $0.host == bookmark.host && $0.username == bookmark.username && $0.protocolKind == bookmark.protocolKind }) {
            bookmarks.insert(bookmark, at: 0)
        }
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }
    }

    func deleteBookmark(_ bookmark: FTPBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }
    }

    private func remember(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(12))
        defaults.set(recents.map(\.path), forKey: recentsKey)
    }

    static let archiveTypes: [UTType] = {
        var types: [UTType] = [.zip, .diskImage, .archive]
        let exts = ["rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso", "img", "dmg", "xar", "pkg", "cpio", "cab", "lha", "lzh", "apk", "ipa", "jar"]
        for ext in exts {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()
}

@MainActor
final class FTPSession: Identifiable, ObservableObject {
    let id = UUID()
    let bookmark: FTPBookmark
    var client: FTPClient?
    var password: String = ""
    @Published var currentPath: String
    @Published var items: [RemoteListingItem] = []
    @Published var isConnected = false
    @Published var selectedIDs: Set<String> = []

    init(bookmark: FTPBookmark) {
        self.bookmark = bookmark
        self.currentPath = bookmark.remotePath
    }

    func joined(_ name: String) -> String {
        if currentPath.hasSuffix("/") { return currentPath + name }
        if currentPath.isEmpty || currentPath == "/" { return "/\(name)" }
        return "\(currentPath)/\(name)"
    }
}

struct PasswordPrompt: Identifiable {
    let id = UUID()
    var url: URL
}

struct PreviewContent: Identifiable {
    let id = UUID()
    var name: String
    var kind: Kind
    var text: String?
    var image: NSImage?
    var data: Data

    enum Kind { case text, image, hex, pdf }

    static func make(name: String, data: Data) -> PreviewContent {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let images = Set(["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "icns"])
        if images.contains(ext), let image = NSImage(data: data) {
            return PreviewContent(name: name, kind: .image, text: nil, image: image, data: data)
        }
        if ext == "pdf" {
            return PreviewContent(name: name, kind: .pdf, text: nil, image: nil, data: data)
        }
        let textExts = Set(["txt", "md", "json", "xml", "plist", "swift", "js", "ts", "py", "rb", "sh", "yml", "yaml", "css", "html", "csv", "log", "ini", "conf", "strings", "c", "h", "m", "cpp", "rs", "go", "java", "kt"])
        if textExts.contains(ext), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return PreviewContent(name: name, kind: .text, text: text, image: nil, data: data)
        }
        if data.count < 512_000, let text = String(data: data, encoding: .utf8), text.contains(where: { !$0.isASCII || $0.isLetter || $0.isNewline || $0.isWhitespace }) && !text.contains("\0") {
            return PreviewContent(name: name, kind: .text, text: text, image: nil, data: data)
        }
        return PreviewContent(name: name, kind: .hex, text: hexDump(data), image: nil, data: data)
    }

    private static func hexDump(_ data: Data) -> String {
        let slice = data.prefix(16 * 256)
        var lines: [String] = []
        for start in stride(from: 0, to: slice.count, by: 16) {
            let row = slice[start..<min(start + 16, slice.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = row.map { byte -> String in
                if byte >= 32 && byte < 127 { return String(UnicodeScalar(byte)) }
                return "."
            }.joined()
            lines.append(String(format: "%08X  %-48@  %@", start, hex as NSString, ascii as NSString))
        }
        if data.count > slice.count {
            lines.append("… \(data.count - slice.count) more bytes")
        }
        return lines.joined(separator: "\n")
    }
}

extension RemoteListingItem {
    init(_ item: FTPListItem) {
        self.init(
            id: item.name,
            name: item.name,
            isDirectory: item.isDirectory,
            size: item.size,
            modified: item.modified,
            permissions: item.permissions
        )
    }
}
