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
    @Published var compressJob: CompressJob?
    @Published var dropOffer: DropOffer?
    @Published var passwordPrompt: PasswordPrompt?
    @Published var preview: PreviewContent?
    @Published var browserLayout: BrowserLayout
    @Published var entrySort: EntrySort
    @Published var sortAscending: Bool
    @Published var ftpSort: EntrySort
    @Published var ftpSortAscending: Bool
    @Published var showPreviewPane: Bool

    private let defaults = UserDefaults.standard
    private let recentsKey = "unzip.recents"
    private let bookmarksKey = "unzip.bookmarks"
    private let layoutKey = "unzip.layout"
    private let sortKey = "unzip.sort"
    private let sortAscKey = "unzip.sortAsc"
    private let previewKey = "unzip.showPreview"

    init() {
        let savedLayout = BrowserLayout(rawValue: defaults.string(forKey: "unzip.layout") ?? "") ?? .details
        let savedSort = EntrySort(rawValue: defaults.string(forKey: "unzip.sort") ?? "") ?? .name
        let savedAscending = defaults.object(forKey: "unzip.sortAsc") as? Bool ?? true
        let savedPreview = defaults.object(forKey: "unzip.showPreview") as? Bool ?? true
        browserLayout = savedLayout
        entrySort = savedSort
        sortAscending = savedAscending
        ftpSort = savedSort
        ftpSortAscending = savedAscending
        showPreviewPane = savedPreview
        recents = (defaults.stringArray(forKey: recentsKey) ?? []).prefix(12).compactMap {
            let url = URL(fileURLWithPath: $0)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let data = defaults.data(forKey: bookmarksKey),
           let saved = try? JSONDecoder().decode([FTPBookmark].self, from: data) {
            bookmarks = saved
        }
    }

    func setLayout(_ layout: BrowserLayout) {
        browserLayout = layout
        defaults.set(layout.rawValue, forKey: layoutKey)
    }

    func setShowPreviewPane(_ visible: Bool) {
        showPreviewPane = visible
        if !visible { preview = nil }
        defaults.set(visible, forKey: previewKey)
    }

    func togglePreviewPane() {
        setShowPreviewPane(!showPreviewPane)
    }

    func setSort(_ sort: EntrySort) {
        if entrySort == sort {
            sortAscending.toggle()
        } else {
            entrySort = sort
            sortAscending = !sort.prefersDescending
        }
        defaults.set(entrySort.rawValue, forKey: sortKey)
        defaults.set(sortAscending, forKey: sortAscKey)
        ftpSort = entrySort
        ftpSortAscending = sortAscending
    }

    func toggleSortDirection() {
        sortAscending.toggle()
        defaults.set(sortAscending, forKey: sortAscKey)
        ftpSortAscending = sortAscending
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

    func receiveDropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var archives: [URL] = []
        var packable: [URL] = []
        for url in urls {
            if FormatDetector.isUnzippable(url) {
                archives.append(url)
            } else {
                packable.append(url)
            }
        }
        for archive in archives {
            open(url: archive)
        }
        if !packable.isEmpty {
            dropOffer = DropOffer(archives: archives, packable: packable)
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
                        localURL: opened.resolvedURL
                    )
                    doc.entries = opened.entries
                    self.documents.append(doc)
                    self.selectedDocumentID = doc.id
                    self.selectedFTPID = nil
                    self.remember(url)
                    self.busyMessage = nil
                    if opened.parts > 1 {
                        self.status = "\(opened.entries.count) items · \(opened.format.displayName) · \(opened.parts) parts joined"
                    } else {
                        self.status = "\(opened.entries.count) items · \(opened.format.displayName)"
                    }
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

    func openSelected() {
        guard let document = selectedDocument, let entry = document.selectedEntries.first else { return }
        openEntry(entry)
    }

    func goBack() { selectedDocument?.goBack() }
    func goForward() { selectedDocument?.goForward() }
    func goUp() { selectedDocument?.goUp() }

    func openEntry(_ entry: ArchiveEntry) {
        guard let document = selectedDocument else { return }
        if entry.isDirectory {
            if !document.filter.isEmpty { document.filter = "" }
            document.navigate(to: entry.path)
            preview = nil
            status = entry.path.isEmpty ? document.title : entry.path
            return
        }
        if entry.isNestedArchive {
            openNestedArchive(entry)
            return
        }
        previewEntry(entry)
    }

    func openNestedArchive(_ entry: ArchiveEntry) {
        guard let document = selectedDocument, let url = document.localURL else { return }
        busyMessage = "Opening \(entry.name)…"
        let format = document.format
        let password = document.password
        Task.detached { [weak self] in
            do {
                let data = try ArchiveEngine.extractData(url: url, format: format, path: entry.path, password: password)
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try data.write(to: dest)
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.open(url: dest)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func previewEntry(_ entry: ArchiveEntry) {
        guard let document = selectedDocument, let url = document.localURL else { return }
        if entry.isDirectory {
            openEntry(entry)
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
        beginCompress(job: CompressJob(format: .zip, suggestedName: destination.deletingPathExtension().lastPathComponent, origin: .local(sources)), options: CompressOptions(), destination: destination)
    }

    func requestCompress(entries: [ArchiveEntry], format: CompressFormat) {
        guard let document = selectedDocument else { return }
        let name = entries.count == 1 ? entries[0].name : document.title
        compressJob = CompressJob(
            format: format,
            suggestedName: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
            origin: .archive(documentID: document.id, entries: entries)
        )
    }

    func requestCompress(local sources: [URL], format: CompressFormat = .zip) {
        let name = sources.first?.deletingPathExtension().lastPathComponent ?? "Archive"
        compressJob = CompressJob(format: format, suggestedName: name, origin: .local(sources))
    }

    func destinationForCompress(job: CompressJob, format: CompressFormat) -> URL? {
        switch job.origin {
        case .local(let urls):
            return ArchiveWriter.destinationBeside(sources: urls, name: job.suggestedName, format: format)
        case .archive:
            if let document = documents.first(where: { $0.id == job.documentID }),
               case .file(let url) = document.source {
                return ArchiveWriter.uniqueURL(
                    in: url.deletingLastPathComponent(),
                    name: job.suggestedName,
                    format: format
                )
            }
            if let document = documents.first(where: { $0.id == job.documentID }), let url = document.localURL {
                return ArchiveWriter.uniqueURL(
                    in: url.deletingLastPathComponent(),
                    name: job.suggestedName,
                    format: format
                )
            }
            return nil
        }
    }

    func beginCompress(job: CompressJob, options: CompressOptions, destination: URL) {
        compressJob = nil
        busyMessage = "Compressing \(destination.lastPathComponent)…"
        progress = 0.2
        let document = documents.first(where: { $0.id == job.documentID })
        let snapshot: ArchiveSnapshot? = document.flatMap { doc in
            guard let url = doc.localURL else { return nil }
            return ArchiveSnapshot(url: url, format: doc.format, password: doc.password, entries: doc.entries)
        }
        Task.detached { [weak self] in
            do {
                let sources = try Self.prepareSources(job: job, snapshot: snapshot)
                try ArchiveWriter.create(from: sources, to: destination, options: options)
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.progress = nil
                    self?.status = options.splitBytes > 0
                        ? "Created split \(options.format.displayName) · \(destination.path)"
                        : "Created \(destination.path)"
                    ArchiveEngine.reveal(destination)
                    self?.open(url: destination)
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

    private struct ArchiveSnapshot: Sendable {
        var url: URL
        var format: ArchiveFormat
        var password: String?
        var entries: [ArchiveEntry]
    }

    nonisolated private static func prepareSources(job: CompressJob, snapshot: ArchiveSnapshot?) throws -> [URL] {
        switch job.origin {
        case .local(let urls):
            return urls
        case .archive(_, let entries):
            guard let snapshot else { throw UnZipError.failed("Archive is no longer open.") }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("UnZip-pack-\(UUID().uuidString)", isDirectory: true)
            let extracted = staging.appendingPathComponent("src", isDirectory: true)
            let packed = staging.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: packed, withIntermediateDirectories: true)
            let expanded = entries.flatMap { root -> [ArchiveEntry] in
                if root.isDirectory {
                    return snapshot.entries.filter { $0.path == root.path || $0.path.hasPrefix(root.path + "/") }
                }
                return [root]
            }
            try ArchiveEngine.extract(
                url: snapshot.url,
                format: snapshot.format,
                destination: extracted,
                entries: expanded.isEmpty ? nil : expanded,
                password: snapshot.password
            )
            for entry in entries {
                let source = extracted.appendingPathComponent(entry.path)
                let dest = packed.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: dest)
                } else if let match = FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: nil)?
                    .compactMap({ $0 as? URL })
                    .first(where: { $0.lastPathComponent == entry.name }) {
                    try FileManager.default.copyItem(at: match, to: dest)
                }
            }
            let items = try FileManager.default.contentsOfDirectory(at: packed, includingPropertiesForKeys: nil)
            guard !items.isEmpty else { throw UnZipError.failed("Could not prepare files to compress.") }
            return items
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
