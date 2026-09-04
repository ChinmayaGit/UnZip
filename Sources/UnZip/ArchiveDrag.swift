import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DragLeaf: Sendable, Hashable {
    var path: String
    var name: String
    var isDirectory: Bool
}

struct ArchiveDragPayload: Sendable {
    var archivePath: String
    var formatRaw: String
    var password: String?
    var roots: [DragLeaf]
    var extractLeaves: [DragLeaf]
    var suggestedName: String
    var isFolderDrop: Bool
    var singleFileExtension: String?

    var fileType: UTType {
        if isFolderDrop { return .folder }
        if let ext = singleFileExtension, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }

    static func make(
        archiveURL: URL,
        format: ArchiveFormat,
        password: String?,
        roots: [ArchiveEntry],
        allEntries: [ArchiveEntry]
    ) -> ArchiveDragPayload {
        let expanded: [ArchiveEntry] = roots.flatMap { root in
            if root.isDirectory {
                return allEntries.filter { $0.path == root.path || $0.path.hasPrefix(root.path + "/") }
            }
            return [root]
        }
        let uniqueRoots = uniqueNames(roots.map { DragLeaf(path: $0.path, name: $0.name, isDirectory: $0.isDirectory) })
        let folderDrop = uniqueRoots.count != 1 || uniqueRoots[0].isDirectory
        let name: String
        if uniqueRoots.count == 1 {
            name = uniqueRoots[0].name
        } else {
            name = archiveURL.deletingPathExtension().lastPathComponent
        }
        return ArchiveDragPayload(
            archivePath: archiveURL.path,
            formatRaw: format.rawValue,
            password: password,
            roots: uniqueRoots,
            extractLeaves: expanded.map { DragLeaf(path: $0.path, name: $0.name, isDirectory: $0.isDirectory) },
            suggestedName: name.isEmpty ? "Untitled" : name,
            isFolderDrop: folderDrop,
            singleFileExtension: folderDrop ? nil : URL(fileURLWithPath: uniqueRoots[0].name).pathExtension
        )
    }

    static func entireArchive(archiveURL: URL, format: ArchiveFormat, password: String?, title: String, entries: [ArchiveEntry]) -> ArchiveDragPayload {
        let name = URL(fileURLWithPath: title).deletingPathExtension().lastPathComponent
        return ArchiveDragPayload(
            archivePath: archiveURL.path,
            formatRaw: format.rawValue,
            password: password,
            roots: [DragLeaf(path: "", name: name, isDirectory: true)],
            extractLeaves: entries.map { DragLeaf(path: $0.path, name: $0.name, isDirectory: $0.isDirectory) },
            suggestedName: name,
            isFolderDrop: true,
            singleFileExtension: nil
        )
    }

    func write(to destination: URL) throws {
        let format = ArchiveFormat(rawValue: formatRaw) ?? .unknown
        let archive = URL(fileURLWithPath: archivePath)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("UnZip-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let extractEntries = extractLeaves.map {
            ArchiveEntry(
                id: $0.path,
                path: $0.path,
                name: $0.name,
                isDirectory: $0.isDirectory,
                compressedSize: 0,
                uncompressedSize: 0,
                modified: nil,
                encrypted: false
            )
        }
        let selection = extractEntries.isEmpty ? nil : extractEntries
        try ArchiveEngine.extract(
            url: archive,
            format: format,
            destination: staging,
            entries: selection,
            password: password
        )

        if !isFolderDrop, let root = roots.first {
            let found = find(root, in: staging)
            try replace(destination, with: found)
            return
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if roots.count == 1, roots[0].isDirectory, !roots[0].path.isEmpty {
            let found = find(roots[0], in: staging)
            try copyContents(of: found, into: destination)
        } else if roots.count == 1, roots[0].path.isEmpty {
            try copyContents(of: staging, into: destination)
        } else {
            for root in roots {
                let found = find(root, in: staging)
                let target = destination.appendingPathComponent(root.name)
                try replace(target, with: found)
            }
        }
    }

    private func find(_ leaf: DragLeaf, in staging: URL) -> URL {
        let direct = staging.appendingPathComponent(leaf.path)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        if let match = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == leaf.name }) {
            return match
        }
        return direct
    }

    private func replace(_ destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func copyContents(of source: URL, into destination: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for child in children {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            try replace(target, with: child)
        }
    }

    private static func uniqueNames(_ leaves: [DragLeaf]) -> [DragLeaf] {
        var seen: [String: Int] = [:]
        return leaves.map { leaf in
            let count = seen[leaf.name, default: 0]
            seen[leaf.name] = count + 1
            if count == 0 { return leaf }
            let url = URL(fileURLWithPath: leaf.name)
            let renamed = "\(url.deletingPathExtension().lastPathComponent) \(count + 1)"
            let ext = url.pathExtension
            var copy = leaf
            copy.name = ext.isEmpty ? renamed : "\(renamed).\(ext)"
            return copy
        }
    }
}

enum DragSession {
    static func provider(for payload: ArchiveDragPayload) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = payload.suggestedName
        provider.registerFileRepresentation(for: payload.fileType, visibility: .all) { completion in
            final class Finish: @unchecked Sendable {
                let run: (URL?, Bool, (any Error)?) -> Void
                init(_ run: @escaping (URL?, Bool, (any Error)?) -> Void) { self.run = run }
            }
            let finish = Finish(completion)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("UnZip-drop-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(payload.suggestedName)
                    try payload.write(to: target)
                    finish.run(target, true, nil)
                } catch {
                    finish.run(nil, false, error)
                }
            }
            return Progress()
        }
        return provider
    }
}

extension OpenDocument {
    func dragPayload(for entry: ArchiveEntry) -> ArchiveDragPayload? {
        guard let url = localURL else { return nil }
        let selected = selectedEntries
        let roots = selected.contains(where: { $0.id == entry.id }) && selected.count > 1 ? selected : [entry]
        return ArchiveDragPayload.make(
            archiveURL: url,
            format: format,
            password: password,
            roots: roots,
            allEntries: entries
        )
    }

    func dragPayloadForCurrentFolder() -> ArchiveDragPayload? {
        guard let url = localURL else { return nil }
        if currentPath.isEmpty {
            return ArchiveDragPayload.entireArchive(
                archiveURL: url,
                format: format,
                password: password,
                title: title,
                entries: entries
            )
        }
        if let folder = entries.first(where: { $0.path == currentPath && $0.isDirectory }) {
            return ArchiveDragPayload.make(
                archiveURL: url,
                format: format,
                password: password,
                roots: [folder],
                allEntries: entries
            )
        }
        return ArchiveDragPayload.entireArchive(
            archiveURL: url,
            format: format,
            password: password,
            title: title,
            entries: entries
        )
    }
}

struct DragPreview: View {
    var name: String
    var icon: String
    var extra: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).lineLimit(1)
                if extra > 0 {
                    Text("+\(extra) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
