import Foundation

enum FormatDetector {
    static func detect(url: URL) -> ArchiveFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ArchiveFormat.from(url: url)
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 16)) ?? Data()
        if prefix.starts(with: [0x50, 0x4B, 0x03, 0x04]) || prefix.starts(with: [0x50, 0x4B, 0x05, 0x06]) || prefix.starts(with: [0x50, 0x4B, 0x07, 0x08]) {
            return .zip
        }
        if prefix.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) {
            return .rar
        }
        if prefix.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return .sevenZ
        }
        if prefix.starts(with: [0x1F, 0x8B]) {
            let name = url.lastPathComponent.lowercased()
            if name.contains(".tar.") || name.hasSuffix(".tgz") { return .tarGz }
            return name.hasSuffix(".gz") && !name.contains(".tar") ? .gzip : .tarGz
        }
        if prefix.starts(with: [0x42, 0x5A, 0x68]) {
            let name = url.lastPathComponent.lowercased()
            return name.contains(".tar.") || name.hasSuffix(".tbz") || name.hasSuffix(".tbz2") ? .tarBz2 : .bzip2
        }
        if prefix.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            let name = url.lastPathComponent.lowercased()
            return name.contains(".tar.") || name.hasSuffix(".txz") ? .tarXz : .xz
        }
        if prefix.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) {
            return .tarZst
        }
        if prefix.starts(with: Array("xar!".utf8)) {
            return .xar
        }
        if prefix.starts(with: [0x78, 0x01]) || prefix.count >= 2 && prefix[0] == 0x78 {
            // could be zlib, fall through to extension
        }
        if isISO(url: url) {
            return url.pathExtension.lowercased() == "dmg" ? .dmg : .iso
        }
        if prefix.starts(with: Array("MSCF".utf8)) {
            return .cab
        }
        return ArchiveFormat.from(url: url)
    }

    private static func isISO(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let offset = UInt64(16 * 2048)
        guard let size = try? handle.seekToEnd(), size > offset + 6 else { return false }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: 6), data.count == 6 else { return false }
        return data[1] == 0x43 && data[2] == 0x44 && data[3] == 0x30 && data[4] == 0x30 && data[5] == 0x31
    }
}
