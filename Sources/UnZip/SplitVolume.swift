import Foundation

enum SplitVolume {
    static func resolve(_ url: URL) throws -> URL {
        let parts = discoverParts(around: url)
        if parts.count <= 1 {
            if isMultipartMarker(url), !hasInfoZipSiblings(url) {
                throw UnZipError.failed(missingPartsMessage(for: url))
            }
            return url
        }
        if let cached = JoinCache.shared.url(for: parts), FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let joined = try join(parts)
        JoinCache.shared.store(joined, for: parts)
        return joined
    }

    static func discoverParts(around url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let lower = name.lowercased()

        if let infoZip = infoZipParts(in: folder, hint: url), infoZip.count > 1 {
            return infoZip
        }
        if let seven = numberedParts(in: folder, prefix: sevenZipPrefix(for: lower) ?? zipNumberPrefix(for: lower) ?? ""), seven.count > 1 {
            return seven
        }
        return [url]
    }

    static func partCount(around url: URL) -> Int {
        max(1, discoverParts(around: url).count)
    }

    private static func infoZipParts(in folder: URL, hint: URL) -> [URL]? {
        let hintName = hint.lastPathComponent
        let base: String
        let ext = hint.pathExtension.lowercased()
        if ext == "zip" {
            base = hint.deletingPathExtension().lastPathComponent
        } else if ext.hasPrefix("z"), Int(ext.dropFirst()) != nil {
            base = hint.deletingPathExtension().lastPathComponent
        } else {
            return nil
        }

        let zip = folder.appendingPathComponent("\(base).zip")
        guard FileManager.default.fileExists(atPath: zip.path) || hintName.lowercased().hasPrefix(base.lowercased()) else {
            return nil
        }

        var parts: [URL] = []
        var missing: [String] = []
        var index = 1
        var sawAny = false
        while index <= 999 {
            let candidates = [
                folder.appendingPathComponent(String(format: "%@.z%02d", base, index)),
                folder.appendingPathComponent(String(format: "%@.z%d", base, index)),
                folder.appendingPathComponent(String(format: "%@.z%03d", base, index))
            ]
            if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                parts.append(found)
                sawAny = true
            } else if sawAny {
                let nextExists = FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(format: "%@.z%02d", base, index + 1)).path)
                if nextExists {
                    missing.append(String(format: "%@.z%02d", base, index))
                } else {
                    break
                }
            } else if index >= 2 {
                break
            }
            index += 1
        }

        let zipExists = FileManager.default.fileExists(atPath: zip.path)
        if !sawAny && !zipExists { return nil }
        if !missing.isEmpty {
            return nil
        }
        if zipExists {
            parts.append(zip)
        }
        return parts.isEmpty ? nil : parts
    }

    private static func numberedParts(in folder: URL, prefix: String) -> [URL]? {
        guard !prefix.isEmpty else { return nil }
        var parts: [URL] = []
        var index = 1
        while index <= 999 {
            let names = [
                String(format: "%@%03d", prefix, index),
                String(format: "%@%02d", prefix, index),
                String(format: "%@%d", prefix, index)
            ]
            if let found = names.map({ folder.appendingPathComponent($0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                parts.append(found)
            } else {
                break
            }
            index += 1
        }
        return parts.count > 1 ? parts : nil
    }

    private static func sevenZipPrefix(for name: String) -> String? {
        if name.contains(".zip.") { return String(name.prefix { $0 != "." }) + ".zip." }
        if name.hasSuffix(".zip.001") || name.range(of: #".zip\.\d+$"#, options: .regularExpression) != nil {
            if let range = name.range(of: ".zip.") {
                return String(name[..<range.upperBound])
            }
        }
        return nil
    }

    private static func zipNumberPrefix(for name: String) -> String? {
        if name.range(of: #"\.\d{3}$"#, options: .regularExpression) != nil {
            return String(name.dropLast(3))
        }
        return nil
    }

    private static func join(_ parts: [URL]) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnZip-joined-\(UUID().uuidString).zip")
        if let zipPart = parts.last(where: { $0.pathExtension.lowercased() == "zip" }),
           parts.contains(where: { $0.pathExtension.lowercased().hasPrefix("z") && $0.pathExtension.lowercased() != "zip" }) {
            let result = try ProcessRunner.run(Toolchain.zip, arguments: ["-s", "0", zipPart.path, "--out", dest.path])
            if result.succeeded, FileManager.default.fileExists(atPath: dest.path) {
                return dest
            }
        }
        try concatenate(parts, to: dest)
        return dest
    }

    private static func concatenate(_ parts: [URL], to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
        }
    }

    private static func isMultipartMarker(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return false }
        let scan = min(size, UInt64(22 + 65535))
        try? handle.seek(toOffset: size - scan)
        guard let data = try? handle.read(upToCount: Int(scan)) else { return false }
        guard let range = data.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards) else { return false }
        let i = range.lowerBound
        guard i + 8 <= data.count else { return false }
        let thisDisk = data.u16(i + 4)
        let startDisk = data.u16(i + 6)
        return thisDisk > 0 || startDisk > 0
    }

    private static func hasInfoZipSiblings(_ url: URL) -> Bool {
        (infoZipParts(in: url.deletingLastPathComponent(), hint: url)?.count ?? 0) > 1
    }

    private static func missingPartsMessage(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return """
        \(url.lastPathComponent) is the last piece of a split ZIP. \
        Put the other parts next to it (for example \(base).z01, \(base).z02, …) and open the .zip again.
        """
    }
}

final class JoinCache: @unchecked Sendable {
    static let shared = JoinCache()
    private let lock = NSLock()
    private var map: [String: URL] = [:]

    func url(for parts: [URL]) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return map[key(for: parts)]
    }

    func store(_ url: URL, for parts: [URL]) {
        lock.lock()
        map[key(for: parts)] = url
        lock.unlock()
    }

    private func key(for parts: [URL]) -> String {
        parts.map { part in
            let size = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(part.path):\(size)"
        }.joined(separator: "|")
    }
}
