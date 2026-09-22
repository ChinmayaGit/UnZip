import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var browser: FileBrowser
    @ObservedObject var covers: FolderCoverStore
    @ViewState private var pathDraft = ""
    @ViewState private var editingPath = false
    @ViewState private var itemFrames: [String: CGRect] = [:]
    @ViewState private var marqueeStart: CGPoint?
    @ViewState private var marqueeCurrent: CGPoint?
    @ViewState private var marqueeOnItem = false
    @ViewState private var marqueeBaseIDs: Set<String> = []

    private var appearance: AppearancePreferences { state.appearance }

    private var items: [FileItem] {
        browser.visibleItems(
            sort: state.entrySort,
            ascending: state.sortAscending,
            foldersFirst: appearance.foldersFirst,
            kind: appearance.kindFilter
        )
    }

    private var layout: BrowserLayout {
        appearance.isLayoutEnabled(state.browserLayout) ? state.browserLayout : appearance.visibleLayouts[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            viewTabs
            Group {
                if let error = browser.errorMessage, items.isEmpty {
                    emptyState(icon: "lock.folder", title: "Can’t open this folder", detail: error)
                } else if items.isEmpty {
                    emptyState(
                        icon: browser.filter.isEmpty ? "folder" : "magnifyingglass",
                        title: browser.filter.isEmpty ? "This folder is empty" : "No matching files",
                        detail: browser.filter.isEmpty ? "Drop files here, or create a new folder." : nil
                    )
                } else if layout == .details {
                    detailsView
                } else if layout == .list || layout == .tiles {
                    listView
                } else {
                    gridView
                }
            }
            .searchable(text: $browser.filter, prompt: "Search this folder")
            .onKeyPress(.return) {
                state.openSelected()
                return .handled
            }
            .onChange(of: browser.selectedIDs) { _, ids in
                state.previewFileSelection(ids)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                acceptDrop(providers, into: browser.currentURL)
            }
            .onKeyPress(.delete) {
                state.trashSelectedFiles()
                return .handled
            }
            if shouldShowMediaBar {
                MediaBar(
                    playback: state.media,
                    height: appearance.musicBarHeight,
                    folderTracks: folderTracks,
                    onOpenPreview: { state.revealMediaPreview() }
                )
            }
        }
        .padding(.bottom, WindowChrome.statusBarHeight)
        .onDeleteCommand { state.trashSelectedFiles() }
        .onAppear { pathDraft = browser.currentURL.path }
        .onChange(of: browser.currentURL) { _, url in
            pathDraft = url.path
            editingPath = false
        }
    }

    private var folderTracks: [URL] {
        browser.items.filter(\.isAudio).map(\.resolvedURL)
    }

    private var shouldShowMediaBar: Bool {
        state.media.item != nil || folderTracks.count >= 1
    }

    private var detailsView: some View {
        Table(items, selection: $browser.selectedIDs) {
            TableColumn(columnTitle("Name", .name)) { item in
                HStack(spacing: 8) {
                    glyph(item, size: appearance.iconSize(for: .details), corner: 4)
                    Text(item.displayName(showExtension: appearance.showExtensions))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fileDrag(item, browser: browser)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard item.canEnter else { return false }
                    return acceptDrop(providers, into: item.url)
                }
            }
            TableColumn(columnTitle("Date", .date)) { item in
                Text(item.dateLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fileDrag(item, browser: browser)
            }
            .width(min: 140, ideal: 170)
            TableColumn(columnTitle("Size", .size)) { item in
                Text(item.sizeLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fileDrag(item, browser: browser)
            }
            .width(min: 70, ideal: 90)
            TableColumn(columnTitle("Kind", .type)) { item in
                Text(item.kindLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fileDrag(item, browser: browser)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first, let item = browser.items.first(where: { $0.id == id }) {
                state.openFileItem(item)
            }
        }
        .background(
            Color(nsColor: .textBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { clearSelection() }
        )
    }

    private var listView: some View {
        List(items, selection: $browser.selectedIDs) { item in
            HStack(spacing: 10) {
                glyph(item, size: appearance.iconSize(for: layout), corner: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName(showExtension: appearance.showExtensions))
                        .lineLimit(1)
                    if layout == .tiles {
                        Text("\(item.kindLabel)  \(item.sizeLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if layout == .list {
                    Text(item.sizeLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .fileDrag(item, browser: browser)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard item.canEnter else { return false }
                return acceptDrop(providers, into: item.url)
            }
            .onTapGesture(count: 2) {
                select(item, exclusive: true)
                state.openFileItem(item)
            }
            .onTapGesture {
                select(item)
            }
            .contextMenu {
                Group { contextButtons(for: item) }
                    .onAppear { selectIfNeeded(item) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(
            Color(nsColor: .textBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { clearSelection() }
        )
    }

    private var gridView: some View {
        let icon = appearance.iconSize(for: layout)
        let tile = appearance.tileWidth(for: layout)
        return GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .textBackgroundColor)
                        .frame(width: geo.size.width, height: max(geo.size.height, 1))
                        .contentShape(Rectangle())
                        .onTapGesture { clearSelection() }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tile, maximum: tile + 28), spacing: 14)], spacing: 16) {
                        ForEach(items) { item in
                            gridItem(item, icon: icon, tile: tile)
                        }
                    }
                    .padding(16)
                    if let rect = marqueeRect {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(Color.accentColor, lineWidth: 1)
                            )
                            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                .coordinateSpace(name: "files")
                .onPreferenceChange(ItemFrameKey.self) { itemFrames = $0 }
                .gesture(marqueeGesture)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contextMenu {
                contextMenu(browser.selectedIDs)
            }
        }
    }

    private func gridItem(_ item: FileItem, icon: CGFloat, tile: CGFloat) -> some View {
        let selected = browser.selectedIDs.contains(item.id)
        return VStack(spacing: 8) {
            glyph(item, size: icon, corner: layout == .gallery ? 16 : 12, selected: selected)
            Text(item.displayName(showExtension: appearance.showExtensions))
                .font(layout == .extraLarge || layout == .gallery ? .callout : .caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: tile - 12, height: 32)
                .padding(.horizontal, 4)
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .frame(width: tile)
        .contentShape(Rectangle())
        .background(itemFrameReporter(item.id))
        .fileDrag(item, browser: browser)
        .onTapGesture(count: 2) {
            select(item, exclusive: true)
            state.openFileItem(item)
        }
        .onTapGesture {
            select(item)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in
                if NSEvent.pressedMouseButtons == 2 {
                    selectIfNeeded(item)
                }
            }
        )
        .contextMenu {
            Group { contextButtons(for: item) }
                .onAppear { selectIfNeeded(item) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard item.canEnter else { return false }
            return acceptDrop(providers, into: item.url)
        }
    }

    private func glyph(_ item: FileItem, size: CGFloat, corner: CGFloat, selected: Bool = false) -> some View {
        FileGlyph(
            item: item,
            size: size,
            corner: corner,
            selected: selected,
            style: item.canEnter ? appearance.coverStyle(for: item.url) : CoverStyle(fit: .crop),
            defaultSymbol: appearance.defaultFolderSymbol,
            covers: covers
        )
        .onAppear {
            covers.request(item, appearance: appearance)
        }
    }

    private func emptyState(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { clearSelection() }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if editingPath {
                    addressField
                } else {
                    breadcrumbTrail
                }
                Button {
                    state.copyCurrentPath()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy path")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )

            Button {
                state.refreshBrowser()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")

            Button {
                state.showDetails()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Details")

            Button {
                state.openTerminal()
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Open Terminal here")

            Text("\(items.count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var breadcrumbTrail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(browser.crumbs, id: \.id) { crumb in
                    HStack(spacing: 6) {
                        if crumb.id > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Group {
                            if crumb.id == 0 {
                                Label(crumb.title, systemImage: "house")
                            } else {
                                Text(crumb.title)
                            }
                        }
                        .foregroundStyle(crumb.url.standardizedFileURL == browser.currentURL.standardizedFileURL ? Color.primary : Color.accentColor)
                        .onTapGesture(count: 2) {
                            pathDraft = browser.currentURL.path
                            editingPath = true
                        }
                        .onTapGesture {
                            browser.navigate(to: crumb.url)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                pathDraft = browser.currentURL.path
                editingPath = true
            }
        }
        .help("Click a folder to go there. Double-click to edit the path.")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            TextField("Path", text: $pathDraft)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .onSubmit {
                    state.goToPath(pathDraft)
                    editingPath = false
                }
            Button {
                editingPath = false
                pathDraft = browser.currentURL.path
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Back to folders")
        }
        .onExitCommand {
            editingPath = false
            pathDraft = browser.currentURL.path
        }
    }

    private var viewTabs: some View {
        HStack(spacing: 8) {
            ForEach(appearance.visibleLayouts) { item in
                Button {
                    state.setLayout(item)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            layout == item ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Picker("Filter", selection: Binding(
                get: { appearance.kindFilter },
                set: { appearance.kindFilter = $0 }
            )) {
                ForEach(KindFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 110)
            Picker("Sort", selection: Binding(
                get: { state.entrySort },
                set: { state.setSort($0) }
            )) {
                ForEach(EntrySort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 140)
            Button {
                state.toggleSortDirection()
            } label: {
                Image(systemName: state.sortAscending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(state.sortAscending ? "Ascending" : "Descending")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func columnTitle(_ title: String, _ sort: EntrySort) -> String {
        guard state.entrySort == sort else { return title }
        return title + (state.sortAscending ? " ↑" : " ↓")
    }

    private func acceptDrop(_ providers: [NSItemProvider], into folder: URL) -> Bool {
        if !browser.draggingURLs.isEmpty {
            state.dropFiles([], into: folder)
            return true
        }
        DroppedFiles.urls(from: providers) { urls in
            state.dropFiles(urls, into: folder)
        }
        return true
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent, !marqueeOnItem else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("files"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeOnItem = itemFrames.contains { $0.value.insetBy(dx: -4, dy: -4).contains(value.startLocation) }
                    marqueeBaseIDs = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                        ? browser.selectedIDs
                        : []
                    if marqueeOnItem { return }
                    if !NSEvent.modifierFlags.contains(.shift), !NSEvent.modifierFlags.contains(.command) {
                        browser.selectedIDs = []
                    }
                }
                if marqueeOnItem { return }
                marqueeCurrent = value.location
                if let rect = marqueeRect {
                    let hits = Set(itemFrames.compactMap { $0.value.intersects(rect) ? $0.key : nil })
                    browser.selectedIDs = marqueeBaseIDs.union(hits)
                }
            }
            .onEnded { value in
                if !marqueeOnItem, abs(value.translation.width) < 4, abs(value.translation.height) < 4,
                   !NSEvent.modifierFlags.contains(.command) {
                    browser.selectedIDs = []
                }
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeOnItem = false
            }
    }

    private func itemFrameReporter(_ id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: ItemFrameKey.self, value: [id: geo.frame(in: .named("files"))])
        }
    }

    private func clearSelection() {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) { return }
        browser.selectedIDs = []
        browser.selectionAnchorID = nil
    }

    private func select(_ item: FileItem, exclusive: Bool = false) {
        let command = !exclusive && NSEvent.modifierFlags.contains(.command)
        let shift = !exclusive && NSEvent.modifierFlags.contains(.shift)
        if shift, let anchor = browser.selectionAnchorID ?? browser.selectedIDs.first,
           let from = items.firstIndex(where: { $0.id == anchor }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            let range = Set(items[min(from, to)...max(from, to)].map(\.id))
            browser.selectedIDs = command ? browser.selectedIDs.union(range) : range
        } else if command {
            if browser.selectedIDs.contains(item.id) {
                browser.selectedIDs.remove(item.id)
            } else {
                browser.selectedIDs.insert(item.id)
            }
            browser.selectionAnchorID = item.id
        } else {
            browser.selectedIDs = [item.id]
            browser.selectionAnchorID = item.id
        }
    }

    private func selectIfNeeded(_ item: FileItem) {
        if !browser.selectedIDs.contains(item.id) {
            select(item)
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        if ids.isEmpty {
            Button("New Folder") { browser.createFolder() }
            Button("Paste") { state.pasteFiles() }
                .disabled(state.fileClipboard.isEmpty && NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil) == false)
            Button("Folder Image…") {
                state.folderImageTarget = FolderImageTarget(url: browser.currentURL, name: browser.currentURL.lastPathComponent)
            }
            Button("Pick Image from Anywhere…") {
                state.pickCoverImage(for: browser.currentURL)
            }
            Button("Details") { state.showDetails() }
            Button("Share…") { state.beginShare() }
        } else if ids.count == 1, let item = browser.items.first(where: { $0.id == ids.first }) {
            contextButtons(for: item)
        } else {
            let selected = browser.items.filter { ids.contains($0.id) }
            Button("Open") {
                for item in selected { state.openFileItem(item) }
            }
            Button("Copy") { state.copyFileItems(selected) }
            Button("Cut") { state.cutFileItems(selected) }
            Button("Paste") { state.pasteFiles() }
            Button("Duplicate") { state.duplicateFileItems(selected) }
            Button("Move To…") { state.moveFileItems(selected) }
            Menu("Compress Selected") {
                Button("ZIP…") { state.requestCompress(local: selected.map(\.url), format: .zip) }
                Button("RAR…") { state.requestCompress(local: selected.map(\.url), format: .rar) }
            }
            Button("Reveal in Finder") {
                if let url = selected.first?.url { ArchiveEngine.reveal(url) }
            }
            Button("Details") { state.showDetails(for: selected) }
            Button("Share…") { state.beginShare(items: selected) }
            if selected.count == 1, let item = selected.first {
                Button("Rename") { state.beginRename(item) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                state.trashFileItems(selected)
            }
        }
    }

    @ViewBuilder
    private func contextButtons(for item: FileItem) -> some View {
        if item.canEnter {
            Button("Open Folder") { state.openFileItem(item) }
            Button("Folder Image…") {
                state.folderImageTarget = FolderImageTarget(url: item.url, name: item.name)
            }
            Button("Pick Image from Anywhere…") {
                state.pickCoverImage(for: item.url)
            }
            Menu("Cover Fit") {
                ForEach(CoverFit.allCases) { fit in
                    Button(fit.title) {
                        var style = appearance.coverStyle(for: item.url)
                        style.fit = fit
                        appearance.setCover(style, for: item.url, applyGlobally: false)
                        state.refreshCovers(for: item.url)
                    }
                }
            }
        } else if item.isImage {
            Button("View Image") { state.openImageGallery(item) }
            Button("Open with Default App") { NSWorkspace.shared.open(item.url) }
        } else if item.isAudio || item.isVideo {
            Button(item.isVideo ? "Play Video" : "Play") { state.playMedia(item) }
            Button("Open with Default App") { NSWorkspace.shared.open(item.url) }
        } else if item.isArchive {
            Button("Open Archive") { state.openFileItem(item) }
            Button("Open with Default App") { NSWorkspace.shared.open(item.url) }
        } else {
            Button("Open") { state.openFileItem(item) }
            Button("Open with Default App") { NSWorkspace.shared.open(item.url) }
        }
        Button("Reveal in Finder") { ArchiveEngine.reveal(item.url) }
        Button("Details") { state.showDetails(for: [item]) }
        Button("Rename") { state.beginRename(item) }
        Button("Share…") { state.beginShare(items: [item]) }
        Divider()
        Button("Copy") { state.copyFileItems([item]) }
        Button("Cut") { state.cutFileItems([item]) }
        Button("Paste") { state.pasteFiles(into: item.canEnter ? item.url : browser.currentURL) }
        Button("Duplicate") { state.duplicateFileItems([item]) }
        Button("Move To…") { state.moveFileItems([item]) }
        Divider()
        Menu("Compress") {
            Button("ZIP…") { state.requestCompress(local: [item.url], format: .zip) }
            Button("RAR…") { state.requestCompress(local: [item.url], format: .rar) }
        }
        Button("New Folder") { browser.createFolder() }
        Divider()
        Button("Move to Trash", role: .destructive) {
            state.trashFileItems([item])
        }
    }
}

struct FileGlyph: View {
    let item: FileItem
    var size: CGFloat
    var corner: CGFloat
    var selected: Bool = false
    var style: CoverStyle
    var defaultSymbol: String
    @ObservedObject var covers: FolderCoverStore

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
            if shouldShowImage, let image = covers.image(for: item.url) {
                fitted(image)
            } else {
                Image(systemName: glyphName)
                    .font(.system(size: max(12, size * 0.38), weight: .medium))
                    .foregroundStyle(item.canEnter ? Color.accentColor : Color.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var shouldShowImage: Bool {
        if item.canEnter {
            return style.mode == .auto || style.mode == .custom
        }
        return item.isImage
    }

    private var glyphName: String {
        if item.canEnter {
            if style.mode == .symbol {
                return style.resolvedSymbol
            }
            return defaultSymbol
        }
        return item.systemImage
    }

    @ViewBuilder
    private func fitted(_ image: NSImage) -> some View {
        let view = Image(nsImage: image).resizable()
        switch style.fit {
        case .crop:
            view.scaledToFill()
                .frame(width: size, height: size)
                .clipped()
        case .fit:
            view.scaledToFit()
                .frame(width: size, height: size)
        case .fitWidth:
            view.scaledToFit()
                .frame(width: size)
                .frame(width: size, height: size)
                .clipped()
        case .fitHeight:
            view.scaledToFit()
                .frame(height: size)
                .frame(width: size, height: size)
                .clipped()
        }
    }
}

private extension View {
    func fileDrag(_ item: FileItem, browser: FileBrowser) -> some View {
        let urls = browser.selectedIDs.contains(item.id) && browser.selectedIDs.count > 1
            ? browser.selectedItems.map(\.url)
            : [item.url]
        let extra = max(0, urls.count - 1)
        return self.onDrag {
            browser.draggingURLs = urls
            let provider = NSItemProvider()
            provider.suggestedName = urls[0].lastPathComponent
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(urls[0].dataRepresentation, nil)
                return nil
            }
            return provider
        } preview: {
            DragPreview(name: item.name, icon: item.systemImage, extra: extra)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3).onChanged { _ in
                browser.draggingURLs = urls
            }
        )
    }
}

private struct ItemFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
