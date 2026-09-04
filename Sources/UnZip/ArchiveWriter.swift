import Foundation

enum ArchiveWriter {
    static func createZip(from sources: [URL], to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if sources.count == 1, let source = sources.first {
            try ProcessRunner.runChecked(Toolchain.ditto, arguments: [
                "-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path
            ])
            return
        }
        let parent = sources.first?.deletingLastPathComponent()
        var args = ["-r", destination.path]
        args.append(contentsOf: sources.map(\.lastPathComponent))
        try ProcessRunner.runChecked(Toolchain.zip, arguments: args, currentDirectory: parent)
    }
}
