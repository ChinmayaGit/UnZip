import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FTPConnectSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var kind: FTPBookmark.Kind = .ftp
    @State private var name = ""
    @State private var host = ""
    @State private var port = "21"
    @State private var username = ""
    @State private var password = ""
    @State private var path = "/"
    @State private var selectedBookmark: FTPBookmark?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Server")
                .font(.title2.weight(.semibold))
            Text("Browse remote folders, download archives, and extract them without leaving UnZip.")
                .foregroundStyle(.secondary)

            Picker("Protocol", selection: $kind) {
                ForEach(FTPBookmark.Kind.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, new in
                if port == "21" || port == "22" || port == "990" {
                    port = new == .sftp ? "22" : new == .ftps ? "990" : "21"
                }
            }

            formField("Name", text: $name, placeholder: "NAS, build server…")
            formField("Host", text: $host, placeholder: "ftp.example.com")
            formField("Port", text: $port, placeholder: "21")
            formField("Username", text: $username, placeholder: "anonymous")
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            formField("Remote path", text: $path, placeholder: "/")

            if kind == .sftp {
                Text("SFTP uses your existing SSH keys or ssh-agent. Password login is not sent through the SFTP batch client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !state.bookmarks.isEmpty {
                Divider()
                Text("Saved servers")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.bookmarks) { bookmark in
                            HStack {
                                Button {
                                    apply(bookmark)
                                } label: {
                                    Label("\(bookmark.name) — \(bookmark.host)", systemImage: "bookmark")
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button(role: .destructive) {
                                    state.deleteBookmark(bookmark)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func formField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func apply(_ bookmark: FTPBookmark) {
        selectedBookmark = bookmark
        kind = bookmark.protocolKind
        name = bookmark.name
        host = bookmark.host
        port = String(bookmark.port)
        username = bookmark.username
        path = bookmark.remotePath
    }

    private func connect() {
        let bookmark = FTPBookmark(
            id: selectedBookmark?.id ?? UUID(),
            name: name.isEmpty ? host : name,
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? (kind == .sftp ? 22 : 21),
            username: username,
            remotePath: path.isEmpty ? "/" : path,
            useTLS: kind == .ftps,
            protocolKind: kind
        )
        dismiss()
        state.connectFTP(bookmark, password: password)
    }
}

struct CreateArchiveSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [URL] = []
    @State private var options = CompressOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Archive")
                .font(.title2.weight(.semibold))
            Text("Choose ZIP or RAR, a storing method, and optional split parts.")
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(height: 120)
                .overlay {
                    if sources.isEmpty {
                        Text("Drop files here or add them below")
                            .foregroundStyle(.secondary)
                    } else {
                        List(sources, id: \.self) { url in
                            Label(url.lastPathComponent, systemImage: "doc")
                        }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    DroppedFiles.urls(from: providers) { urls in
                        sources.append(contentsOf: urls)
                    }
                    return true
                }

            CompressOptionsForm(options: $options)

            if let dest = inPlaceDestination {
                Text("Saves next to the original: \(dest.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Add Files…") { addFiles() }
                Button("Add Folder…") { addFolder() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save elsewhere…") { create(elsewhere: true) }
                    .disabled(sources.isEmpty || !options.format.isAvailable)
                Button("Create \(options.format.displayName)") { create(elsewhere: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sources.isEmpty || !options.format.isAvailable)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            sources.append(contentsOf: panel.urls)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            sources.append(url)
        }
    }

    private var inPlaceDestination: URL? {
        ArchiveWriter.destinationBeside(
            sources: sources,
            name: sources.first?.deletingPathExtension().lastPathComponent ?? "Archive",
            format: options.format
        )
    }

    private func create(elsewhere: Bool) {
        let dest: URL?
        if elsewhere {
            dest = saveDestination(name: sources.first?.deletingPathExtension().lastPathComponent ?? "Archive", format: options.format)
        } else {
            dest = inPlaceDestination
        }
        guard let dest else { return }
        dismiss()
        state.beginCompress(
            job: CompressJob(format: options.format, suggestedName: dest.deletingPathExtension().lastPathComponent, origin: .local(sources)),
            options: options,
            destination: dest
        )
    }
}

struct CompressSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var job: CompressJob
    @State private var options = CompressOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compress \(job.suggestedName)")
                .font(.title2.weight(.semibold))
            Text("Create a ZIP or RAR with a storing method and optional split volumes.")
                .foregroundStyle(.secondary)

            CompressOptionsForm(options: $options)

            if let dest = state.destinationForCompress(job: job, format: options.format) {
                Text("Saves next to the original: \(dest.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save elsewhere…") { create(elsewhere: true) }
                    .disabled(!options.format.isAvailable)
                Button("Create \(options.format.displayName)") { create(elsewhere: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!options.format.isAvailable)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            options.format = job.format
        }
    }

    private func create(elsewhere: Bool) {
        let dest: URL?
        if elsewhere {
            dest = saveDestination(name: job.suggestedName, format: options.format)
        } else {
            dest = state.destinationForCompress(job: job, format: options.format)
        }
        guard let dest else { return }
        dismiss()
        state.beginCompress(job: job, options: options, destination: dest)
    }
}

struct CompressOptionsForm: View {
    @Binding var options: CompressOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Format").font(.headline)
                Picker("Format", selection: $options.format) {
                    ForEach(CompressFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                if options.format == .rar, !CompressFormat.rar.isAvailable {
                    Text("Creating RAR needs the rar command (WinRAR). ZIP is always available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Storing method").font(.headline)
                ForEach(StoreMethod.allCases) { method in
                    Button {
                        options.method = method
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: options.method == method ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(options.method == method ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(method.title).font(.body.weight(.medium))
                                Text(method.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            options.method == method ? Color.accentColor.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Split file").font(.headline)
                Text("Turn a large archive into smaller parts, for example 1 GB into several 200 MB files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Split", selection: $options.split) {
                    ForEach(SplitPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                if options.split == .custom {
                    HStack {
                        TextField("Size", value: $options.customSplitMB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("MB per part")
                            .foregroundStyle(.secondary)
                    }
                }
                if options.splitBytes > 0 {
                    Text("Parts will be about \(ByteFormat.string(options.splitBytes)) each.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct DropOfferSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var offer: DropOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(offer.isFolderDrop ? "Zip this folder?" : "Zip these items?")
                .font(.title2.weight(.semibold))
            Text(offer.isFolderDrop
                 ? "“\(offer.title)” is a folder. The ZIP is created in the same place as the folder."
                 : "These items are not archives. The ZIP is created in the same folder you picked them from.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(offer.packable.prefix(8), id: \.path) { url in
                    Label(url.lastPathComponent, systemImage: FormatDetector.isDirectory(url) ? "folder" : "doc")
                }
                if offer.packable.count > 8 {
                    Text("+\(offer.packable.count - 8) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !offer.archives.isEmpty {
                Text("Opened \(offer.archives.count) archive\(offer.archives.count == 1 ? "" : "s") as well.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Compress as RAR…") {
                    dismiss()
                    state.requestCompress(local: offer.packable, format: .rar)
                }
                .disabled(!CompressFormat.rar.isAvailable)
                Button("Compress as ZIP…") {
                    dismiss()
                    state.requestCompress(local: offer.packable, format: .zip)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

@MainActor
private func saveDestination(name: String, format: CompressFormat) -> URL? {
    let panel = NSSavePanel()
    if format == .zip {
        panel.allowedContentTypes = [.zip]
    } else if let type = UTType(filenameExtension: format.fileExtension) {
        panel.allowedContentTypes = [type]
    }
    panel.nameFieldStringValue = name + ".\(format.fileExtension)"
    panel.title = "Save \(format.displayName)"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

struct PasswordSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var url: URL
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Password required")
                .font(.title3.weight(.semibold))
            Text(url.lastPathComponent)
                .foregroundStyle(.secondary)
            SecureField("Archive password", text: $password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Unlock") {
                    dismiss()
                    state.openWithPassword(password, url: url)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
