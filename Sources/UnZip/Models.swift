import Foundation

enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip, rar, sevenZ, tar, tarGz, tarBz2, tarXz, tarZst
    case gzip, bzip2, xz, iso, dmg, xar, cpio, cab, lha, unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .rar: "RAR"
        case .sevenZ: "7-Zip"
        case .tar: "TAR"
        case .tarGz: "TAR.GZ"
        case .tarBz2: "TAR.BZ2"
        case .tarXz: "TAR.XZ"
        case .tarZst: "TAR.ZST"
        case .gzip: "GZIP"
        case .bzip2: "BZIP2"
        case .xz: "XZ"
        case .iso: "ISO"
        case .dmg: "DMG"
        case .xar: "XAR / PKG"
        case .cpio: "CPIO"
        case .cab: "CAB"
        case .lha: "LHA"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .zip: "doc.zipper"
        case .rar: "shippingbox"
        case .sevenZ: "archivebox"
        case .tar, .tarGz, .tarBz2, .tarXz, .tarZst: "externaldrive.badge.timemachine"
        case .gzip, .bzip2, .xz: "doc.badge.arrow.up"
        case .iso: "opticaldisc"
        case .dmg: "externaldrive"
        case .xar: "shippingbox.and.arrow.backward"
        case .cpio: "cylinder.split.1x2"
        case .cab: "cabinet"
        case .lha: "archivebox.fill"
        case .unknown: "questionmark.folder"
        }
    }

    static func from(url: URL) -> ArchiveFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") || name.hasSuffix(".tbz2") { return .tarBz2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".tar.zst") || name.hasSuffix(".tzst") { return .tarZst }
        let ext = url.pathExtension.lowercased()
        if ext.hasPrefix("z"), ext != "zip", ext != "zipx", Int(ext.dropFirst()) != nil {
            return .zip
        }
        switch ext {
        case "zip", "zipx", "jar", "war", "ear", "apk", "ipa", "whl", "egg", "nupkg", "001": return .zip
        case "rar": return .rar
        case "7z": return .sevenZ
        case "tar": return .tar
        case "gz": return .gzip
        case "bz2": return .bzip2
        case "xz": return .xz
        case "iso", "img", "udf": return .iso
        case "dmg": return .dmg
        case "xar", "pkg": return .xar
        case "cpio": return .cpio
        case "cab": return .cab
        case "lha", "lzh": return .lha
        default: return .unknown
        }
    }
}

struct ArchiveEntry: Identifiable, Hashable, Sendable {
    let id: String
    var path: String
    var name: String
    var isDirectory: Bool
    var compressedSize: Int64
    var uncompressedSize: Int64
    var modified: Date?
    var encrypted: Bool

    var parentPath: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[..<slash])
    }

    var sizeLabel: String {
        if isDirectory { return "—" }
        return ByteFormat.string(uncompressedSize > 0 ? uncompressedSize : compressedSize)
    }

    var kindLabel: String {
        if isDirectory { return "Folder" }
        if encrypted { return "Encrypted" }
        let ext = URL(fileURLWithPath: name).pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }

    var dateLabel: String {
        guard let modified else { return "—" }
        return Self.dateFormatter.string(from: modified)
    }

    var isNestedArchive: Bool {
        guard !isDirectory else { return false }
        let format = ArchiveFormat.from(url: URL(fileURLWithPath: name))
        switch format {
        case .zip, .rar, .sevenZ, .tar, .tarGz, .tarBz2, .tarXz, .tarZst, .iso, .dmg, .xar, .cab, .lha:
            return true
        default:
            return false
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

enum BrowserLayout: String, CaseIterable, Identifiable {
    case details, grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: "Details"
        case .grid: "Grid"
        }
    }

    var systemImage: String {
        switch self {
        case .details: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }
}

enum EntrySort: String, CaseIterable, Identifiable {
    case name, date, type, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date"
        case .type: "Type"
        case .size: "Size"
        }
    }

    var prefersDescending: Bool { self == .date || self == .size }
}

enum FileAppearance {
    static func icon(for entry: ArchiveEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isNestedArchive { return ArchiveFormat.from(url: URL(fileURLWithPath: entry.name)).systemImage }
        switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "icns": return "photo"
        case "pdf": return "doc.richtext"
        case "txt", "md", "log", "rtf": return "doc.plaintext"
        case "mp3", "wav", "aiff", "m4a", "aac": return "waveform"
        case "mp4", "mov", "m4v": return "film"
        case "swift", "js", "ts", "py", "json", "xml", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    static func sort(_ a: ArchiveEntry, _ b: ArchiveEntry, by sort: EntrySort, ascending: Bool) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
        let ordered: Bool
        switch sort {
        case .name:
            ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .date:
            ordered = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
        case .type:
            let typeOrder = a.kindLabel.localizedStandardCompare(b.kindLabel)
            ordered = typeOrder == .orderedSame
                ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                : typeOrder == .orderedAscending
        case .size:
            let left = a.uncompressedSize > 0 ? a.uncompressedSize : a.compressedSize
            let right = b.uncompressedSize > 0 ? b.uncompressedSize : b.compressedSize
            ordered = left == right
                ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                : left < right
        }
        return ascending ? ordered : !ordered
    }
}

enum DocumentSource: Hashable, Sendable {
    case file(URL)
    case ftp(host: String, path: String)
}

@MainActor
final class OpenDocument: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String
    @Published var format: ArchiveFormat
    @Published var source: DocumentSource
    @Published var entries: [ArchiveEntry] = []
    @Published var currentPath: String = ""
    @Published var selectedIDs: Set<String> = []
    @Published var filter: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var localURL: URL?
    @Published var password: String?
    @Published var pathHistory: [String] = [""]
    @Published var historyIndex = 0

    init(title: String, format: ArchiveFormat, source: DocumentSource, localURL: URL? = nil) {
        self.title = title
        self.format = format
        self.source = source
        self.localURL = localURL
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < pathHistory.count - 1 }
    var canGoUp: Bool { !currentPath.isEmpty }

    func visibleEntries(sort: EntrySort, ascending: Bool) -> [ArchiveEntry] {
        let children = entries.filter { entry in
            if entry.path == currentPath { return false }
            if currentPath.isEmpty {
                return entry.parentPath.isEmpty
            }
            return entry.parentPath == currentPath
        }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = query.isEmpty
            ? children
            : entries.filter {
                $0.path.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
            }
        return pool.sorted { FileAppearance.sort($0, $1, by: sort, ascending: ascending) }
    }

    var breadcrumb: [String] {
        if currentPath.isEmpty { return [] }
        return currentPath.split(separator: "/").map(String.init)
    }

    var selectedEntries: [ArchiveEntry] {
        entries.filter { selectedIDs.contains($0.id) }
    }

    func navigate(to path: String) {
        guard path != currentPath else { return }
        if historyIndex < pathHistory.count - 1 {
            pathHistory = Array(pathHistory.prefix(historyIndex + 1))
        }
        pathHistory.append(path)
        historyIndex = pathHistory.count - 1
        currentPath = path
        selectedIDs = []
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentPath = pathHistory[historyIndex]
        selectedIDs = []
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentPath = pathHistory[historyIndex]
        selectedIDs = []
    }

    func goUp() {
        guard canGoUp else { return }
        if let slash = currentPath.lastIndex(of: "/") {
            navigate(to: String(currentPath[..<slash]))
        } else {
            navigate(to: "")
        }
    }

    func goToBreadcrumb(index: Int) {
        navigate(to: breadcrumb.prefix(index + 1).joined(separator: "/"))
    }
}

struct FTPBookmark: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var remotePath: String
    var useTLS: Bool
    var protocolKind: Kind

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case ftp, ftps, sftp
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .ftp: "FTP"
            case .ftps: "FTPS"
            case .sftp: "SFTP"
            }
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 21,
        username: String,
        remotePath: String = "/",
        useTLS: Bool = false,
        protocolKind: Kind = .ftp
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.useTLS = useTLS
        self.protocolKind = protocolKind
    }
}

struct RemoteListingItem: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?
    var permissions: String?

    var sizeLabel: String {
        isDirectory ? "—" : ByteFormat.string(size)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

enum UnZipError: LocalizedError {
    case unsupportedFormat
    case missingTool(String)
    case failed(String)
    case cancelled
    case notConnected
    case passwordRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This file type is not supported."
        case .missingTool(let name): "Install \(name) to open this archive. Try: brew install \(name)"
        case .failed(let message): message
        case .cancelled: "Cancelled."
        case .notConnected: "Not connected."
        case .passwordRequired: "This archive is password protected."
        }
    }
}
