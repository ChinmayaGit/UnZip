import AppKit
import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create ZIP")
                .font(.title2.weight(.semibold))
            Text("Compress folders or files into a ZIP you can browse immediately.")
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(height: 140)
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

            HStack {
                Button("Add Files…") { addFiles() }
                Button("Add Folder…") { addFolder() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create ZIP…") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sources.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
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

    private func create() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = (sources.first?.deletingPathExtension().lastPathComponent ?? "Archive") + ".zip"
        panel.title = "Save ZIP"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        dismiss()
        state.createArchive(from: sources, to: dest)
    }
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
