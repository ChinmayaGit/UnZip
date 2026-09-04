import Foundation

enum ArchiveWriter {
    static func destinationBeside(sources: [URL], name: String, format: CompressFormat) -> URL? {
        guard let first = sources.first else { return nil }
        return uniqueURL(in: first.deletingLastPathComponent(), name: name, format: format)
    }

    static func destinationBeside(folder: URL, format: CompressFormat) -> URL {
        uniqueURL(in: folder.deletingLastPathComponent(), name: folder.deletingPathExtension().lastPathComponent, format: format)
    }

    static func uniqueURL(in folder: URL, name: String, format: CompressFormat) -> URL {
        let base = name.isEmpty ? "Archive" : name
        var dest = folder.appendingPathComponent("\(base).\(format.fileExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) \(index).\(format.fileExtension)")
            index += 1
        }
        return dest
    }

    static func createZip(from sources: [URL], to destination: URL) throws {
        try create(from: sources, to: destination, options: CompressOptions())
    }

    static func create(from sources: [URL], to destination: URL, options: CompressOptions) throws {
        guard !sources.isEmpty else { throw UnZipError.failed("Nothing to compress.") }
        removePrevious(destination)

        switch options.format {
        case .zip:
            try createZip(from: sources, to: destination, options: options)
        case .rar:
            try createRAR(from: sources, to: destination, options: options)
        }
    }

    private static func createZip(from sources: [URL], to destination: URL, options: CompressOptions) throws {
        let parent = commonParent(of: sources)
        var args = ["-q", "-r", options.method.zipFlag]
        if let token = options.zipSplitToken {
            args.append(contentsOf: ["-s", token])
        }
        args.append(destination.path)
        args.append(contentsOf: sources.map { relativePath($0, parent: parent) })
        do {
            try ProcessRunner.runChecked(Toolchain.zip, arguments: args, currentDirectory: parent)
        } catch {
            if Toolchain.sevenZip != nil, options.splitBytes > 0 {
                try createZipWith7z(from: sources, to: destination, options: options, parent: parent)
            } else {
                throw error
            }
        }
    }

    private static func createZipWith7z(from sources: [URL], to destination: URL, options: CompressOptions, parent: URL) throws {
        removePrevious(destination)
        var args = ["a", "-tzip", options.method.sevenZipLevel, "-y"]
        if options.splitBytes > 0 {
            args.append("-v\(max(1, options.splitBytes / 1_000_000))m")
        }
        args.append(destination.path)
        args.append(contentsOf: sources.map { relativePath($0, parent: parent) })
        try ProcessRunner.runChecked(Toolchain.sevenZip!, arguments: args, currentDirectory: parent)
    }

    private static func createRAR(from sources: [URL], to destination: URL, options: CompressOptions) throws {
        guard let rar = Toolchain.rar else {
            throw UnZipError.missingTool("rar")
        }
        let parent = commonParent(of: sources)
        var args = ["a", "-ep1", "-r", "-o+", options.method.rarMethod]
        if options.splitBytes > 0 {
            args.append("-v\(max(1, options.splitBytes / 1_000_000))m")
        }
        args.append(destination.path)
        args.append(contentsOf: sources.map { relativePath($0, parent: parent) })
        try ProcessRunner.runChecked(rar, arguments: args, currentDirectory: parent)
    }

    private static func commonParent(of sources: [URL]) -> URL {
        guard let first = sources.first else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        if sources.count == 1 {
            return first.deletingLastPathComponent()
        }
        var parent = first.deletingLastPathComponent()
        while !sources.allSatisfy({ $0.path.hasPrefix(parent.path) }) {
            let next = parent.deletingLastPathComponent()
            if next.path == parent.path { break }
            parent = next
        }
        return parent
    }

    private static func relativePath(_ url: URL, parent: URL) -> String {
        let full = url.standardizedFileURL.path
        let root = parent.standardizedFileURL.path
        if full.hasPrefix(root + "/") {
            return String(full.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    private static func removePrevious(_ destination: URL) {
        let fm = FileManager.default
        let base = destination.deletingPathExtension()
        let folder = destination.deletingLastPathComponent()
        let name = base.lastPathComponent
        if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for item in items {
                let last = item.lastPathComponent
                if last == destination.lastPathComponent
                    || last.hasPrefix(name + ".z")
                    || last.hasPrefix(name + ".zip.")
                    || last.hasPrefix(name + ".part")
                    || last.hasPrefix(name + ".rar.")
                    || (last.hasPrefix(name) && (last.hasSuffix(".r00") || last.contains(".part") && last.hasSuffix(".rar"))) {
                    try? fm.removeItem(at: item)
                }
            }
        }
        try? fm.removeItem(at: destination)
    }
}
