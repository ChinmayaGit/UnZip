import Foundation

enum ArchiveEngine {
    static func open(url: URL) throws -> (format: ArchiveFormat, entries: [ArchiveEntry]) {
        let format = FormatDetector.detect(url: url)
        let entries = try list(url: url, format: format)
        return (format, entries)
    }

    static func list(url: URL, format: ArchiveFormat) throws -> [ArchiveEntry] {
        switch format {
        case .zip:
            return try ZIPArchive.list(url: url)
        case .rar:
            return try RARArchive.list(url: url)
        case .tar, .tarGz, .tarBz2, .tarXz, .tarZst:
            return try TARArchive.list(url: url, format: format)
        case .gzip, .bzip2, .xz:
            return SingleFileArchive.list(url: url, format: format)
        case .iso:
            return try ISOArchive.list(url: url)
        case .dmg:
            return try DMGArchive.list(url: url)
        case .sevenZ, .xar, .cpio, .cab, .lha:
            return try ExternalArchive.list(url: url)
        case .unknown:
            if let entries = try? ZIPArchive.list(url: url), !entries.isEmpty { return entries }
            if let entries = try? TARArchive.list(url: url, format: .tar), !entries.isEmpty { return entries }
            return try ExternalArchive.list(url: url)
        }
    }

    static func extract(url: URL, format: ArchiveFormat, destination: URL, entries: [ArchiveEntry]?, password: String?) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        switch format {
        case .zip:
            try ZIPArchive.extract(url: url, destination: destination, entries: entries, password: password)
        case .rar:
            try RARArchive.extract(url: url, destination: destination, entries: entries, password: password)
        case .tar, .tarGz, .tarBz2, .tarXz, .tarZst:
            try TARArchive.extract(url: url, destination: destination, entries: entries, format: format)
        case .gzip, .bzip2, .xz:
            try SingleFileArchive.extract(url: url, destination: destination, format: format)
        case .iso:
            try ISOArchive.extract(url: url, destination: destination, entries: entries)
        case .dmg:
            try DMGArchive.extract(url: url, destination: destination, entries: entries)
        case .sevenZ, .xar, .cpio, .cab, .lha, .unknown:
            try ExternalArchive.extract(url: url, destination: destination, password: password)
        }
    }

    static func extractData(url: URL, format: ArchiveFormat, path: String, password: String?) throws -> Data {
        switch format {
        case .zip:
            return try ZIPArchive.extractData(url: url, path: path, password: password)
        case .rar:
            return try RARArchive.extractData(url: url, path: path, password: password)
        case .tar, .tarGz, .tarBz2, .tarXz, .tarZst:
            return try TARArchive.extractData(url: url, path: path, format: format)
        case .gzip, .bzip2, .xz:
            return try SingleFileArchive.extractData(url: url, format: format)
        case .iso:
            return try ISOArchive.extractData(url: url, path: path)
        case .dmg:
            return try DMGArchive.extractData(url: url, path: path)
        case .sevenZ, .xar, .cpio, .cab, .lha, .unknown:
            return try ExternalArchive.extractData(url: url, path: path, password: password)
        }
    }

    static func reveal(_ url: URL) {
        _ = try? ProcessRunner.run("/usr/bin/open", arguments: ["-R", url.path])
    }

    static func openInFinder(_ url: URL) {
        _ = try? ProcessRunner.run("/usr/bin/open", arguments: [url.path])
    }
}
