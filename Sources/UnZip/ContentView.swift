import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } content: {
            Group {
                if let document = state.selectedDocument {
                    ArchiveBrowserView(document: document)
                } else if let session = state.selectedFTP {
                    FTPBrowserView(session: session)
                } else {
                    WelcomeView()
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        } detail: {
            PreviewPane()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        }
        .toolbar { toolbar }
        .navigationTitle(title)
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .alert("UnZip", isPresented: Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
        .sheet(isPresented: $state.showFTPSheet) {
            FTPConnectSheet()
        }
        .sheet(isPresented: $state.showCreateSheet) {
            CreateArchiveSheet()
        }
        .sheet(item: $state.passwordPrompt) { prompt in
            PasswordSheet(url: prompt.url)
        }
    }

    private var title: String {
        if let document = state.selectedDocument { return document.title }
        if let session = state.selectedFTP { return session.bookmark.name }
        return "UnZip"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.openPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open archive")

            Button {
                state.showFTPSheet = true
            } label: {
                Label("FTP", systemImage: "network")
            }
            .help("Connect to FTP or SFTP")

            Button {
                state.showCreateSheet = true
            } label: {
                Label("Create ZIP", systemImage: "plus.square.on.square")
            }
            .help("Compress files into a ZIP")

            Button {
                state.extractSelected()
            } label: {
                Label("Extract", systemImage: "rectangle.and.arrow.up.right.and.arrow.down.left")
            }
            .disabled(state.selectedDocument == nil)
            .help("Extract selected items or the whole archive")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let busy = state.busyMessage {
                ProgressView()
                    .controlSize(.small)
                Text(busy)
            } else {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text(state.status)
            }
            Spacer()
            if let progress = state.progress {
                ProgressView(value: progress)
                    .frame(width: 120)
            }
            Text(state.capabilities)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        DroppedFiles.urls(from: providers) { urls in
            for url in urls { state.open(url: url) }
        }
        return !providers.isEmpty
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: Binding(
            get: {
                if let id = state.selectedDocumentID { return id.uuidString }
                if let id = state.selectedFTPID { return id.uuidString }
                return nil
            },
            set: { value in
                guard let value else { return }
                if let doc = state.documents.first(where: { $0.id.uuidString == value }) {
                    state.selectedDocumentID = doc.id
                    state.selectedFTPID = nil
                } else if let session = state.ftpSessions.first(where: { $0.id.uuidString == value }) {
                    state.selectedFTPID = session.id
                    state.selectedDocumentID = nil
                }
            }
        )) {
            if !state.documents.isEmpty {
                Section("Archives") {
                    ForEach(state.documents) { document in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title).lineLimit(1)
                                Text(document.format.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: document.format.systemImage)
                        }
                        .tag(document.id.uuidString)
                        .contextMenu {
                            Button("Extract…") {
                                state.selectedDocumentID = document.id
                                state.extractSelected()
                            }
                            Button("Reveal in Finder") {
                                if let url = document.localURL {
                                    ArchiveEngine.reveal(url)
                                }
                            }
                            Divider()
                            Button("Close", role: .destructive) {
                                state.close(document)
                            }
                        }
                    }
                }
            }

            Section("Servers") {
                ForEach(state.ftpSessions) { session in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.bookmark.name).lineLimit(1)
                            Text("\(session.bookmark.protocolKind.displayName) · \(session.bookmark.host)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: session.isConnected ? "externaldrive.connected.to.line.below" : "network")
                    }
                    .tag(session.id.uuidString)
                    .contextMenu {
                        Button("Disconnect", role: .destructive) {
                            state.disconnectFTP(session)
                        }
                    }
                }
                ForEach(state.bookmarks) { bookmark in
                    Button {
                        state.showFTPSheet = true
                    } label: {
                        Label(bookmark.name, systemImage: "bookmark")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            state.deleteBookmark(bookmark)
                        }
                    }
                }
                Button {
                    state.showFTPSheet = true
                } label: {
                    Label("Connect to Server…", systemImage: "plus")
                }
            }

            if !state.recents.isEmpty {
                Section("Recent") {
                    ForEach(state.recents, id: \.self) { url in
                        Button {
                            state.open(url: url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: ArchiveFormat.from(url: url).systemImage)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 88, height: 88)
                Image(systemName: "doc.zipper")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.primary)
            }
            VStack(spacing: 8) {
                Text("UnZip")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Read ZIP, RAR, ISO, TAR, 7Z, DMG and more.\nExtract locally or pull archives over FTP.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 10) {
                dropZone
                HStack(spacing: 10) {
                    Button("Open Archive…") { state.openPanel() }
                        .keyboardShortcut("o", modifiers: .command)
                    Button("Connect FTP…") { state.showFTPSheet = true }
                    Button("Create ZIP…") { state.showCreateSheet = true }
                }
                .controlSize(.large)
            }

            HStack(spacing: 18) {
                capability("ZIP / JAR / APK", "doc.zipper")
                capability("RAR / 7Z", "shippingbox")
                capability("ISO / DMG", "opticaldisc")
                capability("FTP / SFTP", "network")
            }
            .padding(.top, 8)

            if !Toolchain.rarReady {
                Text("For RAR and 7Z extraction, install extra tools: brew install unar p7zip")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.35))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.06) : Color.clear)
            )
            .frame(width: 420, height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Text("Drop archives here")
                        .font(.headline)
                    Text("ZIP, RAR, ISO, TAR, DMG, 7Z")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
                DroppedFiles.urls(from: providers) { urls in
                    for url in urls { state.open(url: url) }
                }
                return true
            }
    }

    private func capability(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 90)
    }
}

struct ArchiveBrowserView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var document: OpenDocument

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Table(document.visibleEntries, selection: $document.selectedIDs) {
                TableColumn("Name") { entry in
                    Label(entry.name.isEmpty ? entry.path : entry.name, systemImage: entry.isDirectory ? "folder" : icon(for: entry.name))
                        .lineLimit(1)
                }
                TableColumn("Size") { entry in
                    Text(entry.sizeLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                TableColumn("Kind") { entry in
                    Text(entry.isDirectory ? "Folder" : (entry.encrypted ? "Encrypted" : kind(entry.name)))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    Button("Extract Selected…") { state.extractSelected() }
                    if ids.count == 1, let entry = document.entries.first(where: { $0.id == ids.first }) {
                        Button("Preview") { state.previewEntry(entry) }
                    }
                }
            }
            .onTapGesture(count: 2) {
                if let entry = document.selectedEntries.first {
                    state.previewEntry(entry)
                }
            }
            .searchable(text: $document.filter, prompt: "Filter files")
        }
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                document.currentPath = ""
                document.selectedIDs = []
            } label: {
                Image(systemName: "internaldrive")
            }
            .buttonStyle(.borderless)
            .help("Archive root")

            ForEach(Array(document.breadcrumb.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button(part) {
                    document.currentPath = document.breadcrumb.prefix(index + 1).joined(separator: "/")
                    document.selectedIDs = []
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(document.visibleEntries.count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func icon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "txt", "md", "log": return "doc.plaintext"
        case "zip", "rar", "7z": return "doc.zipper"
        case "mp3", "wav", "aiff": return "waveform"
        case "mp4", "mov": return "film"
        default: return "doc"
        }
    }

    private func kind(_ name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }
}

struct FTPBrowserView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: FTPSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    state.ftpUp()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .disabled(session.currentPath == "/" || session.currentPath.isEmpty)

                Text(session.currentPath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
                Button {
                    state.refreshFTP(session)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button("Upload…") { upload() }
                Button("Disconnect", role: .destructive) {
                    state.disconnectFTP(session)
                }
            }
            .padding(10)
            .background(.bar)

            Table(session.items, selection: $session.selectedIDs) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                }
                TableColumn("Size") { item in
                    Text(item.sizeLabel).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(80)
                TableColumn("Permissions") { item in
                    Text(item.permissions ?? "—").foregroundStyle(.tertiary).monospaced()
                }
                .width(110)
            }
            .onTapGesture(count: 2) {
                if let item = session.items.first(where: { session.selectedIDs.contains($0.id) }) {
                    state.ftpOpen(item)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let item = session.items.first(where: { $0.id == id }) {
                    Button(item.isDirectory ? "Open" : "Download & Open") {
                        state.ftpOpen(item)
                    }
                }
            }
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.uploadToFTP(local: url)
        }
    }
}

struct PreviewPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let preview = state.preview {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(preview.name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Text(ByteFormat.string(Int64(preview.data.count)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    Divider()
                    switch preview.kind {
                    case .text:
                        ScrollView {
                            Text(preview.text ?? "")
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    case .hex:
                        ScrollView {
                            Text(preview.text ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    case .image:
                        if let image = preview.image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .pdf:
                        PDFPreview(data: preview.data)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "eye")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Select a file to preview")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct PDFPreview: NSViewRepresentable {
    var data: Data

    func makeNSView(context: Context) -> NSView {
        let view = PDFKitShim(data: data)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#if canImport(PDFKit)
import PDFKit
private final class PDFKitShim: PDFView {
    init(data: Data) {
        super.init(frame: .zero)
        document = PDFDocument(data: data)
        autoScales = true
    }

    required init?(coder: NSCoder) { nil }
}
#else
private final class PDFKitShim: NSView {
    init(data: Data) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
}
#endif
