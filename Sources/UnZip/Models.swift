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
        switch url.pathExtension.lowercased() {
        case "zip", "zipx", "jar", "war", "ear", "apk", "ipa", "whl", "egg", "nupkg": return .zip
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

    init(title: String, format: ArchiveFormat, source: DocumentSource, localURL: URL? = nil) {
        self.title = title
        self.format = format
        self.source = source
        self.localURL = localURL
    }

    var visibleEntries: [ArchiveEntry] {
        let children = entries.filter { entry in
            if entry.path == currentPath { return false }
            if currentPath.isEmpty {
                return entry.parentPath.isEmpty
            }
            return entry.parentPath == currentPath
        }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return children.sorted(by: Self.sort) }
        return entries
            .filter { $0.path.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted(by: Self.sort)
    }

    var breadcrumb: [String] {
        if currentPath.isEmpty { return [] }
        return currentPath.split(separator: "/").map(String.init)
    }

    var selectedEntries: [ArchiveEntry] {
        entries.filter { selectedIDs.contains($0.id) }
    }

    static func sort(_ a: ArchiveEntry, _ b: ArchiveEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
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
