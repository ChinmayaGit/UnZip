import AppKit
import SwiftUI

struct FileDetailsTarget: Identifiable {
    var items: [FileItem]
    var id: String { items.map(\.id).sorted().joined(separator: "|") }
}

struct FileDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let items: [FileItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(items.count == 1 ? "Details" : "\(items.count) Items")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if items.count == 1, let item = items.first {
                single(item)
            } else {
                multiple
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 320)
    }

    @ViewBuilder
    private func single(_ item: FileItem) -> some View {
        let info = FileDetailsInfo(url: item.resolvedURL, fallback: item)
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(item.kindLabel)
                    .foregroundStyle(.secondary)
            }
        }
        detailRow("Path", info.path)
        detailRow("Size", info.size)
        detailRow("Created", info.created)
        detailRow("Modified", info.modified)
        if let extra = info.dimensions {
            detailRow("Dimensions", extra)
        }
        HStack {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.path, forType: .string)
            }
            Button("Reveal in Finder") { ArchiveEngine.reveal(item.url) }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var multiple: some View {
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 10) {
            detailRow("Items", "\(items.count)")
            detailRow("Size", ByteFormat.string(bytes))
            detailRow("Location", items.first?.url.deletingLastPathComponent().path ?? "")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        Text(item.name)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FileDetailsInfo {
    var path: String
    var size: String
    var created: String
    var modified: String
    var dimensions: String?

    init(url: URL, fallback: FileItem) {
        path = url.path
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .totalFileSizeKey, .creationDateKey, .contentModificationDateKey
        ])
        let bytes = Int64(values?.totalFileSize ?? values?.fileSize ?? Int(fallback.size))
        size = fallback.isDirectory ? "—" : ByteFormat.string(bytes)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        created = values?.creationDate.map { formatter.string(from: $0) } ?? "—"
        modified = (values?.contentModificationDate ?? fallback.modified).map { formatter.string(from: $0) } ?? "—"
        if FolderCover.isImage(url), let image = NSImage(contentsOf: url) {
            let size = image.size
            dimensions = "\(Int(size.width)) × \(Int(size.height))"
        } else {
            dimensions = nil
        }
    }
}

struct RenameSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let item: FileItem
    @ViewState private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename")
                .font(.title2.weight(.semibold))
            Text(item.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { name = item.name }
    }

    private func save() {
        state.renameFileItem(item, to: name)
        dismiss()
    }
}
