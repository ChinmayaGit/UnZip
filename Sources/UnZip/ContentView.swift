import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if state.showPreviewPane {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } content: {
                    browserColumn
                        .navigationSplitViewColumnWidth(min: 420, ideal: 620)
                } detail: {
                    PreviewPane()
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } detail: {
                    browserColumn
                }
            }
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
        .sheet(item: $state.compressJob) { job in
            CompressSheet(job: job)
        }
        .sheet(item: $state.passwordPrompt) { prompt in
            PasswordSheet(url: prompt.url)
        }
        .sheet(item: $state.dropOffer) { offer in
            DropOfferSheet(offer: offer)
        }
    }

    private var title: String {
        if let document = state.selectedDocument { return document.title }
        if let session = state.selectedFTP { return session.bookmark.name }
        return "UnZip"
    }

    @ViewBuilder
    private var browserColumn: some View {
        if let document = state.selectedDocument {
            ArchiveBrowserView(document: document)
        } else if let session = state.selectedFTP {
            FTPBrowserView(session: session)
        } else {
            WelcomeView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                state.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!(state.selectedDocument?.canGoBack ?? false))
            .help("Back")

            Button {
                state.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!(state.selectedDocument?.canGoForward ?? false))
            .help("Forward")

            Button {
                state.goUp()
            } label: {
                Label("Enclosing Folder", systemImage: "chevron.up")
            }
            .disabled(!(state.selectedDocument?.canGoUp ?? false))
            .help("Enclosing folder")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: Binding(
                get: { state.browserLayout },
                set: { state.setLayout($0) }
            )) {
                ForEach(BrowserLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.systemImage).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("Details or grid view")

            Button {
                state.togglePreviewPane()
            } label: {
                Label(
                    state.showPreviewPane ? "Hide Preview" : "Show Preview",
                    systemImage: state.showPreviewPane ? "sidebar.right" : "rectangle"
                )
            }
            .help(state.showPreviewPane ? "Hide the preview pane" : "Show the preview pane")

            Menu {
                ForEach(EntrySort.allCases) { sort in
                    Button {
                        state.setSort(sort)
                    } label: {
                        HStack {
                            Text(sort.title)
                            if state.entrySort == sort {
                                Image(systemName: state.sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
                Divider()
                Button(state.sortAscending ? "Descending" : "Ascending") {
                    state.toggleSortDirection()
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort by name, date, type, or size")

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
            Text("Drag files to Desktop or any folder to extract")
                .foregroundStyle(.tertiary)
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
            state.receiveDropped(urls)
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
                        .onDrag {
                            if let payload = document.dragPayloadForCurrentFolder() {
                                return DragSession.provider(for: payload)
                            }
                            return NSItemProvider()
                        } preview: {
                            DragPreview(name: document.title, icon: document.format.systemImage)
                        }
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
                Text("Drop an archive to open it, or drop a folder or file to zip it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Text("ZIP, RAR, ISO, TAR, 7Z, DMG — and any folder or file you want to compress.")
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

            Text("In Finder, right-click a folder or file → Services → Zip with UnZip")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
                    Text(hovering ? "Release to open or zip" : "Drop archives or folders")
                        .font(.headline)
                    Text("Archives open · folders and files can be zipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
                DroppedFiles.urls(from: providers) { urls in
                    state.receiveDropped(urls)
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

    private var entries: [ArchiveEntry] {
        document.visibleEntries(sort: state.entrySort, ascending: state.sortAscending)
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Group {
                if entries.isEmpty {
                    emptyFolder
                } else if state.browserLayout == .details {
                    detailsView
                } else {
                    gridView
                }
            }
            .searchable(text: $document.filter, prompt: "Search inside archive")
            .onKeyPress(.return) {
                state.openSelected()
                return .handled
            }
        }
    }

    private var detailsView: some View {
        Table(entries, selection: $document.selectedIDs) {
            TableColumn(columnTitle("Name", .name)) { entry in
                Label(entry.name.isEmpty ? entry.path : entry.name, systemImage: FileAppearance.icon(for: entry))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .extractDrag(entry, document: document)
            }
            TableColumn(columnTitle("Date", .date)) { entry in
                Text(entry.dateLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .extractDrag(entry, document: document)
            }
            .width(min: 140, ideal: 170)
            TableColumn(columnTitle("Size", .size)) { entry in
                Text(entry.sizeLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .extractDrag(entry, document: document)
            }
            .width(min: 70, ideal: 90)
            TableColumn(columnTitle("Kind", .type)) { entry in
                Text(entry.kindLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .extractDrag(entry, document: document)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first, let entry = document.entries.first(where: { $0.id == id }) {
                state.openEntry(entry)
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 12)], spacing: 16) {
                ForEach(entries) { entry in
                    gridItem(entry)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        }
    }

    private func gridItem(_ entry: ArchiveEntry) -> some View {
        let selected = document.selectedIDs.contains(entry.id)
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                    .frame(width: 72, height: 72)
                Image(systemName: FileAppearance.icon(for: entry))
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.primary)
            }
            Text(entry.name.isEmpty ? entry.path : entry.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 96, height: 32)
                .padding(.horizontal, 4)
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .frame(width: 108)
        .contentShape(Rectangle())
        .extractDrag(entry, document: document)
        .onTapGesture(count: 2) {
            document.selectedIDs = [entry.id]
            state.openEntry(entry)
        }
        .onTapGesture {
            select(entry)
        }
        .contextMenu {
            contextButtons(for: entry)
        }
    }

    private var emptyFolder: some View {
        VStack(spacing: 8) {
            Image(systemName: document.filter.isEmpty ? "folder" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(document.filter.isEmpty ? "This folder is empty" : "No matching files")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                document.navigate(to: "")
            } label: {
                Label(document.title, systemImage: document.format.systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .help("Archive root — drag to extract")
            .onDrag {
                if let payload = document.dragPayloadForCurrentFolder() {
                    return DragSession.provider(for: payload)
                }
                return NSItemProvider()
            } preview: {
                DragPreview(name: document.currentPath.isEmpty ? document.title : document.breadcrumb.last ?? document.title, icon: document.format.systemImage)
            }

            ForEach(Array(document.breadcrumb.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button(part) {
                    document.goToBreadcrumb(index: index)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !document.filter.isEmpty {
                Text("Search results")
                    .foregroundStyle(.secondary)
            }
            Picker("Sort", selection: Binding(
                get: { state.entrySort },
                set: { state.setSort($0) }
            )) {
                ForEach(EntrySort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 92)
            Button {
                state.toggleSortDirection()
            } label: {
                Image(systemName: state.sortAscending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(state.sortAscending ? "Ascending" : "Descending")
            Text("\(entries.count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func columnTitle(_ title: String, _ sort: EntrySort) -> String {
        guard state.entrySort == sort else { return title }
        return title + (state.sortAscending ? " ↑" : " ↓")
    }

    private func select(_ entry: ArchiveEntry) {
        if NSEvent.modifierFlags.contains(.command) {
            if document.selectedIDs.contains(entry.id) {
                document.selectedIDs.remove(entry.id)
            } else {
                document.selectedIDs.insert(entry.id)
            }
        } else {
            document.selectedIDs = [entry.id]
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        if !ids.isEmpty {
            if ids.count == 1, let entry = document.entries.first(where: { $0.id == ids.first }) {
                contextButtons(for: entry)
            } else {
                let selected = document.entries.filter { ids.contains($0.id) }
                Button("Extract Selected…") { state.extractSelected() }
                Menu("Compress Selected") {
                    Button("ZIP…") { state.requestCompress(entries: selected, format: .zip) }
                    Button("RAR…") { state.requestCompress(entries: selected, format: .rar) }
                }
            }
        }
    }

    @ViewBuilder
    private func contextButtons(for entry: ArchiveEntry) -> some View {
        if entry.isDirectory {
            Button("Open Folder") { state.openEntry(entry) }
        } else if entry.isNestedArchive {
            Button("Open Archive") { state.openEntry(entry) }
            Button("Preview") { state.previewEntry(entry) }
        } else {
            Button("Open") { state.openEntry(entry) }
        }
        Button("Extract…") { state.extractSelected() }
        if entry.isDirectory {
            Divider()
            Menu("Compress Folder") {
                Button("ZIP…") { state.requestCompress(entries: [entry], format: .zip) }
                Button("RAR…") { state.requestCompress(entries: [entry], format: .rar) }
            }
        } else {
            Menu("Compress") {
                Button("ZIP…") { state.requestCompress(entries: [entry], format: .zip) }
                Button("RAR…") { state.requestCompress(entries: [entry], format: .rar) }
            }
        }
        Text("Or drag to Desktop, Finder, or another app")
    }
}

private extension View {
    func extractDrag(_ entry: ArchiveEntry, document: OpenDocument) -> some View {
        let extra = document.selectedEntries.contains(where: { $0.id == entry.id }) ? max(0, document.selectedIDs.count - 1) : 0
        return self.onDrag {
            if let payload = document.dragPayload(for: entry) {
                return DragSession.provider(for: payload)
            }
            return NSItemProvider()
        } preview: {
            DragPreview(
                name: entry.name.isEmpty ? entry.path : entry.name,
                icon: FileAppearance.icon(for: entry),
                extra: extra
            )
        }
    }
}

struct FTPBrowserView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: FTPSession

    private var items: [RemoteListingItem] {
        session.items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            let ascending = state.ftpSortAscending
            let result: Bool
            switch state.ftpSort {
            case .name: result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date: result = (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            case .type: result = (lhs.isDirectory ? "Folder" : "File").localizedStandardCompare(rhs.isDirectory ? "Folder" : "File") == .orderedAscending
            case .size: result = lhs.size < rhs.size
            }
            return ascending ? result : !result
        }
    }

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

            if state.browserLayout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 12)], spacing: 16) {
                        ForEach(items) { item in
                            VStack(spacing: 8) {
                                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(item.isDirectory ? Color.accentColor : Color.primary)
                                    .frame(width: 72, height: 72)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(item.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 96)
                            }
                            .onTapGesture(count: 2) { state.ftpOpen(item) }
                            .onTapGesture { session.selectedIDs = [item.id] }
                        }
                    }
                    .padding(16)
                }
            } else {
                Table(items, selection: $session.selectedIDs) {
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
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let item = session.items.first(where: { $0.id == id }) {
                        Button(item.isDirectory ? "Open Folder" : "Download & Open") {
                            state.ftpOpen(item)
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let item = session.items.first(where: { $0.id == id }) {
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
                        Button {
                            state.setShowPreviewPane(false)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Hide preview")
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
                VStack(spacing: 12) {
                    Image(systemName: "eye")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Select a file to preview")
                        .foregroundStyle(.secondary)
                    Button("Hide Preview") {
                        state.setShowPreviewPane(false)
                    }
                    .controlSize(.small)
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
