import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var documents: [OpenDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published var ftpSessions: [FTPSession] = []
    @Published var selectedFTPID: UUID?
    @Published var fileBrowser = FileBrowser()
    @Published var bookmarks: [FTPBookmark] = []
    @Published var recents: [URL] = []
    @Published var status: String = "Browse files or drop an archive."
    @Published var progress: Double?
    @Published var busyMessage: String?
    @Published var alertMessage: String?
    @Published var showFTPSheet = false
    @Published var showCreateSheet = false
    @Published var showExtractSheet = false
    @Published var compressJob: CompressJob?
    @Published var dropOffer: DropOffer?
    @Published var passwordPrompt: PasswordPrompt?
    @Published var preview: PreviewContent?
    @Published var browserLayout: BrowserLayout
    @Published var entrySort: EntrySort
    @Published var sortAscending: Bool
    @Published var ftpSort: EntrySort
    @Published var ftpSortAscending: Bool
    @Published var showPreviewPane: Bool
    @Published var showSettings = false
    @Published var folderImageTarget: FolderImageTarget?
    @Published var fileDetails: FileDetailsTarget?
    @Published var renameTarget: FileItem?
    @Published var appearance = AppearancePreferences()
    @Published var media = MediaPlayback()
    @Published var gallery = ImageGallery()
    @Published var share = FileShare()
    @Published var showShareSheet = false
    @Published var volumes = VolumeStore()

    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard
    private let recentsKey = "unzip.recents"
    private let bookmarksKey = "unzip.bookmarks"
    private let layoutKey = "unzip.layout"
    private let sortKey = "unzip.sort"
    private let sortAscKey = "unzip.sortAsc"
    private let previewKey = "unzip.showPreview"

    init() {
        let savedLayout = BrowserLayout(rawValue: defaults.string(forKey: "unzip.layout") ?? "") ?? .grid
        let savedSort = EntrySort(rawValue: defaults.string(forKey: "unzip.sort") ?? "") ?? .name
        let savedAscending = defaults.object(forKey: "unzip.sortAsc") as? Bool ?? true
        let savedPreview = defaults.object(forKey: "unzip.showPreview") as? Bool ?? true
        browserLayout = savedLayout
        entrySort = savedSort
        sortAscending = savedAscending
        ftpSort = savedSort
        ftpSortAscending = savedAscending
        showPreviewPane = savedPreview
        recents = (defaults.stringArray(forKey: recentsKey) ?? []).prefix(12).compactMap {
            let url = URL(fileURLWithPath: $0)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let data = defaults.data(forKey: bookmarksKey),
           let saved = try? JSONDecoder().decode([FTPBookmark].self, from: data) {
            bookmarks = saved
        }
        status = "\(fileBrowser.items.count) items · \(fileBrowser.currentURL.path)"
        fileBrowser.reload(showHidden: appearance.showHidden)
        fileBrowser.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        appearance.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        media.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        gallery.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        share.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        volumes.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.leaveMissingVolume()
            }
            .store(in: &cancellables)
        if !appearance.isLayoutEnabled(browserLayout) {
            browserLayout = appearance.visibleLayouts[0]
        }
    }

    func refreshCovers(for url: URL? = nil) {
        if let url {
            fileBrowser.covers.invalidate(url)
        } else {
            fileBrowser.covers.invalidateAll()
        }
        objectWillChange.send()
    }

    func refreshBrowser() {
        fileBrowser.covers.invalidateAll()
        fileBrowser.reload()
        for item in fileBrowser.items {
            fileBrowser.covers.request(item, appearance: appearance)
        }
        status = "Refreshed \(fileBrowser.currentURL.lastPathComponent)"
    }

    func pickCoverImage(for folder: URL) {
        guard let path = appearance.importCoverImage() else { return }
        var style = appearance.coverStyle(for: folder)
        style.mode = .custom
        style.imagePath = path
        appearance.setCover(style, for: folder, applyGlobally: false)
        refreshCovers(for: folder)
        if let item = FileItem(url: folder, includeHidden: true) {
            fileBrowser.covers.request(item, appearance: appearance)
        }
        status = "Updated folder image"
    }

    func beginShare(items: [FileItem]? = nil) {
        share.start()
        let selected = items ?? selectedFileItems()
        let urls = selected.isEmpty ? [fileBrowser.currentURL] : selected.map(\.url)
        share.publish(urls)
        showShareSheet = true
        status = share.status
    }

    func receiveFromPeer(_ peer: NearbyPeer) {
        let folder = fileBrowser.currentURL
        busyMessage = "Receiving from \(peer.name)…"
        Task {
            do {
                let count = try await share.receive(from: peer, into: folder)
                fileBrowser.reload()
                busyMessage = nil
                share.receiveNote = "Saved \(count) item\(count == 1 ? "" : "s") from \(peer.name)"
                status = share.receiveNote ?? ""
            } catch {
                busyMessage = nil
                alertMessage = error.localizedDescription
            }
        }
    }

    func beginRename(_ item: FileItem? = nil) {
        if let item {
            renameTarget = item
            return
        }
        renameTarget = selectedFileItems().first
    }

    func renameFileItem(_ item: FileItem, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "." && name != "..", !name.contains("/") else {
            alertMessage = "Enter a valid name."
            return
        }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(name)
        if dest.standardizedFileURL == item.url.standardizedFileURL {
            renameTarget = nil
            return
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            alertMessage = "“\(name)” already exists."
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            fileBrowser.reload()
            fileBrowser.selectedIDs = [dest.standardizedFileURL.path]
            fileBrowser.selectionAnchorID = dest.standardizedFileURL.path
            renameTarget = nil
            status = "Renamed to \(name)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func playMedia(_ item: FileItem) {
        playMedia(url: item.resolvedURL)
    }

    func playMedia(url: URL) {
        preview = nil
        let tracks: [URL]
        if MediaKind.isVideo(url) {
            tracks = fileBrowser.items.filter(\.isVideo).map(\.resolvedURL)
        } else {
            tracks = fileBrowser.items.filter(\.isAudio).map(\.resolvedURL)
        }
        media.play(url, queue: tracks)
        if MediaKind.isVideo(url) {
            setShowPreviewPane(true)
        }
        status = "Playing \(url.lastPathComponent)"
    }

    func openImageGallery(_ item: FileItem) {
        let images = fileBrowser.items.filter(\.isImage).map(\.resolvedURL)
        gallery.open(url: item.resolvedURL, folderImages: images)
        status = item.resolvedURL.path
    }

    func goToPath(_ raw: String) {
        let trimmed = (raw as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            alertMessage = "That path doesn’t exist."
            return
        }
        let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        showFiles(at: folder)
        if !isDirectory.boolValue, let item = fileBrowser.items.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }) {
            fileBrowser.selectedIDs = [item.id]
            previewFileSelection([item.id])
        }
        status = fileBrowser.currentURL.path
    }

    func copyCurrentPath() {
        let path = fileBrowser.currentURL.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        status = "Copied path"
    }

    func openTerminal(at url: URL? = nil) {
        let folder = url ?? fileBrowser.currentURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", folder.path]
        do {
            try process.run()
            status = "Opened Terminal in \(folder.lastPathComponent)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func showDetails(for items: [FileItem]? = nil) {
        let target = items ?? selectedFileItems()
        if target.isEmpty {
            if let folder = FileItem(url: fileBrowser.currentURL, includeHidden: true) {
                fileDetails = FileDetailsTarget(items: [folder])
            }
            return
        }
        fileDetails = FileDetailsTarget(items: target)
    }

    func revealMediaPreview() {
        if media.item == nil, let first = fileBrowser.items.first(where: \.isAudio) {
            playMedia(first)
        }
        if !showPreviewPane {
            setShowPreviewPane(true)
        }
    }

    var isShowingFiles: Bool {
        selectedDocumentID == nil && selectedFTPID == nil
    }

    var canGoBack: Bool {
        if let document = selectedDocument { return document.canGoBack }
        if selectedFTP != nil { return false }
        return fileBrowser.canGoBack
    }

    var canGoForward: Bool {
        if let document = selectedDocument { return document.canGoForward }
        if selectedFTP != nil { return false }
        return fileBrowser.canGoForward
    }

    var canGoUp: Bool {
        if let document = selectedDocument { return document.canGoUp }
        if let session = selectedFTP {
            return session.currentPath != "/" && !session.currentPath.isEmpty
        }
        return fileBrowser.canGoUp
    }

    func showFiles(at url: URL? = nil) {
        selectedDocumentID = nil
        selectedFTPID = nil
        preview = nil
        if let url {
            fileBrowser.navigate(to: url)
        }
        status = "\(fileBrowser.items.count) items · \(fileBrowser.currentURL.path)"
    }

    func ejectVolume(_ volume: MountedVolume) {
        if isShowingFiles, volume.contains(fileBrowser.currentURL) {
            showFiles(at: FileLocation.home.url)
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            volumes.refresh()
            status = "Ejected \(volume.name)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func leaveMissingVolume() {
        guard isShowingFiles else { return }
        let current = fileBrowser.currentURL
        guard current.path.hasPrefix("/Volumes/") else { return }
        if volumes.volume(containing: current) != nil { return }
        if FileManager.default.fileExists(atPath: current.path) { return }
        showFiles(at: FileLocation.home.url)
        status = "That drive was ejected."
    }

    func setLayout(_ layout: BrowserLayout) {
        browserLayout = layout
        defaults.set(layout.rawValue, forKey: layoutKey)
    }

    func setShowPreviewPane(_ visible: Bool) {
        showPreviewPane = visible
        if !visible { preview = nil }
        defaults.set(visible, forKey: previewKey)
    }

    func togglePreviewPane() {
        setShowPreviewPane(!showPreviewPane)
    }

    func setSort(_ sort: EntrySort) {
        if entrySort == sort {
            sortAscending.toggle()
        } else {
            entrySort = sort
            sortAscending = !sort.prefersDescending
        }
        defaults.set(entrySort.rawValue, forKey: sortKey)
        defaults.set(sortAscending, forKey: sortAscKey)
        ftpSort = entrySort
        ftpSortAscending = sortAscending
    }

    func toggleSortDirection() {
        sortAscending.toggle()
        defaults.set(sortAscending, forKey: sortAscKey)
        ftpSortAscending = sortAscending
    }

    var selectedDocument: OpenDocument? {
        documents.first(where: { $0.id == selectedDocumentID })
    }

    var selectedFTP: FTPSession? {
        ftpSessions.first(where: { $0.id == selectedFTPID })
    }

    var capabilities: String {
        var parts = ["ZIP", "TAR", "GZ", "ISO", "DMG"]
        if Toolchain.rarReady { parts.append("RAR") }
        if Toolchain.sevenReady { parts.append("7Z") }
        if Toolchain.unar != nil { parts.append("CAB/LHA") }
        return parts.joined(separator: " · ")
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.archiveTypes
        panel.title = "Open Archive"
        if panel.runModal() == .OK {
            for url in panel.urls {
                open(url: url)
            }
        }
    }

    func receiveDropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var archives: [URL] = []
        var packable: [URL] = []
        for url in urls {
            if FormatDetector.isUnzippable(url) {
                archives.append(url)
            } else {
                packable.append(url)
            }
        }
        for archive in archives {
            open(url: archive)
        }
        if !packable.isEmpty {
            dropOffer = DropOffer(archives: archives, packable: packable)
        }
    }

    func open(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        busyMessage = "Reading \(url.lastPathComponent)…"
        status = busyMessage ?? ""
        Task.detached { [weak self] in
            do {
                let opened = try ArchiveEngine.open(url: url)
                await MainActor.run {
                    guard let self else { return }
                    let doc = OpenDocument(
                        title: url.lastPathComponent,
                        format: opened.format,
                        source: .file(url),
                        localURL: opened.resolvedURL
                    )
                    doc.entries = opened.entries
                    self.documents.append(doc)
                    self.selectedDocumentID = doc.id
                    self.selectedFTPID = nil
                    self.remember(url)
                    self.busyMessage = nil
                    if opened.parts > 1 {
                        self.status = "\(opened.entries.count) items · \(opened.format.displayName) · \(opened.parts) parts joined"
                    } else {
                        self.status = "\(opened.entries.count) items · \(opened.format.displayName)"
                    }
                    self.preview = nil
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                    self?.status = "Could not open archive."
                    if let zipError = error as? UnZipError, case .passwordRequired = zipError {
                        self?.passwordPrompt = PasswordPrompt(url: url)
                    }
                }
            }
        }
    }

    func openWithPassword(_ password: String, url: URL) {
        passwordPrompt = nil
        busyMessage = "Unlocking…"
        Task.detached { [weak self] in
            do {
                let format = FormatDetector.detect(url: url)
                let entries = try ArchiveEngine.list(url: url, format: format)
                await MainActor.run {
                    guard let self else { return }
                    let doc = OpenDocument(title: url.lastPathComponent, format: format, source: .file(url), localURL: url)
                    doc.entries = entries
                    doc.password = password
                    self.documents.append(doc)
                    self.selectedDocumentID = doc.id
                    self.busyMessage = nil
                    self.status = "Unlocked · \(entries.count) items"
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func close(_ document: OpenDocument) {
        documents.removeAll { $0.id == document.id }
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.last?.id
            preview = nil
        }
    }

    func extractSelected(to destination: URL? = nil) {
        guard let document = selectedDocument, let url = document.localURL else { return }
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.title = "Extract To"
            panel.prompt = "Extract"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            dest = chosen
        }
        let entries = document.selectedEntries.isEmpty ? nil : document.selectedEntries
        let format = document.format
        let password = document.password
        busyMessage = "Extracting…"
        progress = 0.15
        Task.detached { [weak self] in
            do {
                try ArchiveEngine.extract(url: url, format: format, destination: dest, entries: entries, password: password)
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.progress = nil
                    self?.status = "Extracted to \(dest.lastPathComponent)"
                    ArchiveEngine.openInFinder(dest)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.progress = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func openSelected() {
        if let document = selectedDocument, let entry = document.selectedEntries.first {
            openEntry(entry)
            return
        }
        if let session = selectedFTP, let item = session.items.first(where: { session.selectedIDs.contains($0.id) }) {
            ftpOpen(item)
            return
        }
        if let item = fileBrowser.selectedItems.first {
            openFileItem(item)
        }
    }

    func goBack() {
        if selectedDocument != nil {
            selectedDocument?.goBack()
            return
        }
        if selectedFTP != nil { return }
        fileBrowser.goBack()
        status = fileBrowser.currentURL.path
    }

    func goForward() {
        if selectedDocument != nil {
            selectedDocument?.goForward()
            return
        }
        if selectedFTP != nil { return }
        fileBrowser.goForward()
        status = fileBrowser.currentURL.path
    }

    func goUp() {
        if selectedDocument != nil {
            selectedDocument?.goUp()
            return
        }
        if selectedFTP != nil {
            ftpUp()
            return
        }
        fileBrowser.goUp()
        status = fileBrowser.currentURL.path
    }

    func openFileItem(_ item: FileItem) {
        let url = item.resolvedURL
        var isDirectory = item.canEnter
        if item.isAlias {
            isDirectory = FormatDetector.isDirectory(url) && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
        }
        if isDirectory {
            fileBrowser.navigate(to: url)
            preview = nil
            status = url.path
            return
        }
        if FormatDetector.isUnzippable(url) {
            open(url: url)
            return
        }
        if item.isImage {
            openImageGallery(item)
            return
        }
        if MediaKind.isAudio(url) || MediaKind.isVideo(url) {
            playMedia(item)
            return
        }
        if showPreviewPane, isPreviewable(url) {
            previewLocal(url)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openFiles(_ urls: [URL], with application: URL) {
        OpenWith.open(urls, with: application)
        let name = FileManager.default.displayName(atPath: application.path)
        if urls.count == 1 {
            status = "Opened \(urls[0].lastPathComponent) with \(name)"
        } else {
            status = "Opened \(urls.count) items with \(name)"
        }
    }

    func setDefaultOpenWith(_ application: URL, for file: URL) {
        let name = FileManager.default.displayName(atPath: application.path)
        OpenWith.setDefault(application, for: file) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.alertMessage = error
                } else {
                    let kind = file.pathExtension.isEmpty
                        ? (OpenWith.contentType(for: file)?.localizedDescription ?? "this type")
                        : ".\(file.pathExtension)"
                    self?.status = "\(name) is now the default for \(kind)"
                }
            }
        }
    }

    func previewFileSelection(_ ids: Set<String>) {
        guard isShowingFiles, showPreviewPane, ids.count == 1,
              let item = fileBrowser.items.first(where: { $0.id == ids.first }),
              !item.canEnter else {
            if isShowingFiles { preview = nil }
            return
        }
        if item.isAudio || item.isVideo {
            playMedia(item)
            return
        }
        previewLocal(item.resolvedURL)
    }

    func previewLocal(_ url: URL) {
        if MediaKind.isAudio(url) || MediaKind.isVideo(url) {
            playMedia(url: url)
            return
        }
        busyMessage = "Loading preview…"
        Task.detached { [weak self] in
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values.isDirectory == true {
                    await MainActor.run {
                        self?.busyMessage = nil
                        self?.preview = nil
                    }
                    return
                }
                let size = values.fileSize ?? 0
                if size > 25_000_000 {
                    await MainActor.run {
                        self?.busyMessage = nil
                        self?.preview = nil
                        self?.status = "\(url.lastPathComponent) is too large to preview"
                    }
                    return
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let content = PreviewContent.make(name: url.lastPathComponent, data: data)
                await MainActor.run {
                    self?.preview = content
                    self?.busyMessage = nil
                    self?.status = url.path
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    @Published var fileClipboard: [URL] = []
    @Published var fileClipboardCuts = false

    func selectedFileItems() -> [FileItem] {
        let selected = fileBrowser.selectedItems
        return selected.isEmpty ? [] : selected
    }

    func copySelectedFiles() {
        copyFileItems(selectedFileItems())
    }

    func cutSelectedFiles() {
        cutFileItems(selectedFileItems())
    }

    func trashSelectedFiles() {
        trashFileItems(selectedFileItems())
    }

    func selectAllFiles() {
        fileBrowser.selectedIDs = Set(fileBrowser.items.map(\.id))
    }

    func copyFileItems(_ items: [FileItem]) {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        fileClipboard = urls
        fileClipboardCuts = false
        writePasteboard(urls)
        status = urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) items"
    }

    func cutFileItems(_ items: [FileItem]) {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        fileClipboard = urls
        fileClipboardCuts = true
        writePasteboard(urls)
        status = urls.count == 1 ? "Cut \(urls[0].lastPathComponent)" : "Cut \(urls.count) items"
    }

    func pasteFiles(into folder: URL? = nil) {
        let dest = folder ?? fileBrowser.currentURL
        let urls: [URL]
        if !fileClipboard.isEmpty {
            urls = fileClipboard
        } else {
            urls = pasteboardURLs()
        }
        guard !urls.isEmpty else { return }
        if fileClipboardCuts {
            moveURLs(urls, into: dest)
            fileClipboard = []
            fileClipboardCuts = false
        } else {
            copyURLs(urls, into: dest)
        }
    }

    func duplicateFileItems(_ items: [FileItem]) {
        copyURLs(items.map(\.url), into: fileBrowser.currentURL)
    }

    func moveFileItems(_ items: [FileItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.title = "Move To"
        panel.prompt = "Move"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        moveURLs(items.map(\.url), into: dest)
    }

    func dropFiles(_ urls: [URL], into folder: URL) {
        let incoming = fileBrowser.draggingURLs.isEmpty ? urls : fileBrowser.draggingURLs
        fileBrowser.draggingURLs = []
        guard !incoming.isEmpty else { return }
        let unique = Array(Set(incoming.map { $0.standardizedFileURL }))
        let archives = unique.filter { FormatDetector.isUnzippable($0) && !FormatDetector.isDirectory($0) }
        let files = unique.filter { !archives.contains($0) }
        if !files.isEmpty {
            if NSEvent.modifierFlags.contains(.option) {
                copyURLs(files, into: folder)
            } else {
                moveURLs(files, into: folder)
            }
        }
        if !archives.isEmpty, files.isEmpty {
            receiveDropped(archives)
        }
    }

    func trashFileItems(_ items: [FileItem]) {
        let current = fileBrowser.currentURL.standardizedFileURL
        let blocked = items.filter { ProtectedLocations.contains($0.url) || $0.url.standardizedFileURL == current }
        let allowed = items.filter { item in
            !ProtectedLocations.contains(item.url) && item.url.standardizedFileURL != current
        }
        if !blocked.isEmpty, allowed.isEmpty {
            let name = blocked[0].name
            alertMessage = "“\(name)” is a special folder and can’t be moved to the Trash."
            return
        }
        guard !allowed.isEmpty else { return }
        let urls = allowed.map(\.url)
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.fileBrowser.reload()
                self.fileBrowser.selectedIDs.subtract(allowed.map(\.id))
                if let error {
                    self.alertMessage = error.localizedDescription
                } else {
                    self.status = urls.count == 1
                        ? "Moved \(urls[0].lastPathComponent) to Trash"
                        : "Moved \(urls.count) items to Trash"
                    if !blocked.isEmpty {
                        self.status += " · skipped \(blocked.map(\.name).joined(separator: ", "))"
                    }
                }
            }
        }
    }

    private func copyURLs(_ urls: [URL], into folder: URL) {
        do {
            for url in urls {
                let dest = uniqueURL(in: folder, name: url.lastPathComponent)
                if url.standardizedFileURL == dest.standardizedFileURL { continue }
                try FileManager.default.copyItem(at: url, to: dest)
            }
            fileBrowser.reload()
            status = urls.count == 1
                ? "Copied \(urls[0].lastPathComponent)"
                : "Copied \(urls.count) items"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func moveURLs(_ urls: [URL], into folder: URL) {
        do {
            for url in urls {
                let dest = uniqueURL(in: folder, name: url.lastPathComponent)
                if url.standardizedFileURL == dest.standardizedFileURL { continue }
                if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                    continue
                }
                if dest.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") {
                    throw UnZipError.failed("Cannot move a folder into itself.")
                }
                try FileManager.default.moveItem(at: url, to: dest)
            }
            fileBrowser.reload()
            status = urls.count == 1
                ? "Moved \(urls[0].lastPathComponent)"
                : "Moved \(urls.count) items"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var dest = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) { return dest }
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        var index = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            dest = folder.appendingPathComponent(next)
            index += 1
        } while FileManager.default.fileExists(atPath: dest.path)
        return dest
    }

    private func writePasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setPropertyList(urls.map(\.path), forType: .init("NSFilenamesPboardType"))
    }

    private func pasteboardURLs() -> [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func isPreviewable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if FolderCover.isImage(url) { return true }
        if MediaKind.isAudio(url) || MediaKind.isVideo(url) { return true }
        if ext == "pdf" { return true }
        let textExts: Set<String> = [
            "txt", "md", "json", "xml", "plist", "swift", "js", "ts", "py", "rb", "sh",
            "yml", "yaml", "css", "html", "csv", "log", "ini", "conf", "strings",
            "c", "h", "m", "cpp", "rs", "go", "java", "kt"
        ]
        return textExts.contains(ext)
    }

    func openEntry(_ entry: ArchiveEntry) {
        guard let document = selectedDocument else { return }
        if entry.isDirectory {
            if !document.filter.isEmpty { document.filter = "" }
            document.navigate(to: entry.path)
            preview = nil
            status = entry.path.isEmpty ? document.title : entry.path
            return
        }
        if entry.isNestedArchive {
            openNestedArchive(entry)
            return
        }
        previewEntry(entry)
    }

    func openNestedArchive(_ entry: ArchiveEntry) {
        guard let document = selectedDocument, let url = document.localURL else { return }
        busyMessage = "Opening \(entry.name)…"
        let format = document.format
        let password = document.password
        Task.detached { [weak self] in
            do {
                let data = try ArchiveEngine.extractData(url: url, format: format, path: entry.path, password: password)
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try data.write(to: dest)
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.open(url: dest)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func previewEntry(_ entry: ArchiveEntry) {
        guard let document = selectedDocument, let url = document.localURL else { return }
        if entry.isDirectory {
            openEntry(entry)
            return
        }
        busyMessage = "Loading preview…"
        let format = document.format
        let password = document.password
        Task.detached { [weak self] in
            do {
                let data = try ArchiveEngine.extractData(url: url, format: format, path: entry.path, password: password)
                let content = PreviewContent.make(name: entry.name, data: data)
                await MainActor.run {
                    self?.preview = content
                    self?.busyMessage = nil
                    self?.status = entry.path
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func createArchive(from sources: [URL], to destination: URL) {
        beginCompress(job: CompressJob(format: .zip, suggestedName: destination.deletingPathExtension().lastPathComponent, origin: .local(sources)), options: CompressOptions(), destination: destination)
    }

    func requestCompress(entries: [ArchiveEntry], format: CompressFormat) {
        guard let document = selectedDocument else { return }
        let name = entries.count == 1 ? entries[0].name : document.title
        compressJob = CompressJob(
            format: format,
            suggestedName: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
            origin: .archive(documentID: document.id, entries: entries)
        )
    }

    func requestCompress(local sources: [URL], format: CompressFormat = .zip) {
        let name = sources.first?.deletingPathExtension().lastPathComponent ?? "Archive"
        compressJob = CompressJob(format: format, suggestedName: name, origin: .local(sources))
    }

    func destinationForCompress(job: CompressJob, format: CompressFormat) -> URL? {
        switch job.origin {
        case .local(let urls):
            return ArchiveWriter.destinationBeside(sources: urls, name: job.suggestedName, format: format)
        case .archive:
            if let document = documents.first(where: { $0.id == job.documentID }),
               case .file(let url) = document.source {
                return ArchiveWriter.uniqueURL(
                    in: url.deletingLastPathComponent(),
                    name: job.suggestedName,
                    format: format
                )
            }
            if let document = documents.first(where: { $0.id == job.documentID }), let url = document.localURL {
                return ArchiveWriter.uniqueURL(
                    in: url.deletingLastPathComponent(),
                    name: job.suggestedName,
                    format: format
                )
            }
            return nil
        }
    }

    func beginCompress(job: CompressJob, options: CompressOptions, destination: URL) {
        compressJob = nil
        busyMessage = "Compressing \(destination.lastPathComponent)…"
        progress = 0.2
        let document = documents.first(where: { $0.id == job.documentID })
        let snapshot: ArchiveSnapshot? = document.flatMap { doc in
            guard let url = doc.localURL else { return nil }
            return ArchiveSnapshot(url: url, format: doc.format, password: doc.password, entries: doc.entries)
        }
        Task.detached { [weak self] in
            do {
                let sources = try Self.prepareSources(job: job, snapshot: snapshot)
                try ArchiveWriter.create(from: sources, to: destination, options: options)
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.progress = nil
                    self?.status = options.splitBytes > 0
                        ? "Created split \(options.format.displayName) · \(destination.path)"
                        : "Created \(destination.path)"
                    ArchiveEngine.reveal(destination)
                    self?.open(url: destination)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.progress = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private struct ArchiveSnapshot: Sendable {
        var url: URL
        var format: ArchiveFormat
        var password: String?
        var entries: [ArchiveEntry]
    }

    nonisolated private static func prepareSources(job: CompressJob, snapshot: ArchiveSnapshot?) throws -> [URL] {
        switch job.origin {
        case .local(let urls):
            return urls
        case .archive(_, let entries):
            guard let snapshot else { throw UnZipError.failed("Archive is no longer open.") }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("UnZip-pack-\(UUID().uuidString)", isDirectory: true)
            let extracted = staging.appendingPathComponent("src", isDirectory: true)
            let packed = staging.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: packed, withIntermediateDirectories: true)
            let expanded = entries.flatMap { root -> [ArchiveEntry] in
                if root.isDirectory {
                    return snapshot.entries.filter { $0.path == root.path || $0.path.hasPrefix(root.path + "/") }
                }
                return [root]
            }
            try ArchiveEngine.extract(
                url: snapshot.url,
                format: snapshot.format,
                destination: extracted,
                entries: expanded.isEmpty ? nil : expanded,
                password: snapshot.password
            )
            for entry in entries {
                let source = extracted.appendingPathComponent(entry.path)
                let dest = packed.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: dest)
                } else if let match = FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: nil)?
                    .compactMap({ $0 as? URL })
                    .first(where: { $0.lastPathComponent == entry.name }) {
                    try FileManager.default.copyItem(at: match, to: dest)
                }
            }
            let items = try FileManager.default.contentsOfDirectory(at: packed, includingPropertiesForKeys: nil)
            guard !items.isEmpty else { throw UnZipError.failed("Could not prepare files to compress.") }
            return items
        }
    }

    func connectFTP(_ bookmark: FTPBookmark, password: String) {
        let session = FTPSession(bookmark: bookmark)
        ftpSessions.append(session)
        selectedFTPID = session.id
        selectedDocumentID = nil
        busyMessage = "Connecting to \(bookmark.host)…"
        Task.detached { [weak self] in
            do {
                if bookmark.protocolKind == .sftp {
                    let items = try SFTPClient.list(host: bookmark.host, port: bookmark.port, username: bookmark.username, path: bookmark.remotePath)
                    await MainActor.run {
                        session.items = items.map(RemoteListingItem.init)
                        session.currentPath = bookmark.remotePath
                        session.isConnected = true
                        self?.busyMessage = nil
                        self?.status = "SFTP \(bookmark.host)"
                    }
                } else {
                    let client = FTPClient()
                    try client.connect(
                        host: bookmark.host,
                        port: UInt16(bookmark.port),
                        username: bookmark.username,
                        password: password,
                        useTLS: bookmark.protocolKind == .ftps || bookmark.useTLS
                    )
                    if bookmark.remotePath != "/" && !bookmark.remotePath.isEmpty {
                        try? client.cwd(bookmark.remotePath)
                    }
                    let items = try client.list()
                    await MainActor.run {
                        session.client = client
                        session.items = items.map(RemoteListingItem.init)
                        session.currentPath = client.currentPath
                        session.isConnected = true
                        session.password = password
                        self?.busyMessage = nil
                        self?.status = "FTP \(bookmark.host)\(client.currentPath)"
                    }
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                    self?.ftpSessions.removeAll { $0.id == session.id }
                }
            }
        }
        saveBookmark(bookmark)
    }

    func ftpOpen(_ item: RemoteListingItem) {
        guard let session = selectedFTP else { return }
        if item.isDirectory {
            browseFTP(session, path: session.joined(item.name))
        } else {
            downloadAndOpen(item, session: session)
        }
    }

    func ftpUp() {
        guard let session = selectedFTP else { return }
        var parts = session.currentPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        parts.removeLast()
        let next = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        browseFTP(session, path: next)
    }

    func browseFTP(_ session: FTPSession, path: String) {
        busyMessage = "Listing…"
        let bookmark = session.bookmark
        let client = session.client
        Task.detached { [weak self] in
            do {
                let items: [FTPListItem]
                if bookmark.protocolKind == .sftp {
                    items = try SFTPClient.list(host: bookmark.host, port: bookmark.port, username: bookmark.username, path: path)
                } else if let client {
                    try client.cwd(path)
                    items = try client.list()
                } else {
                    throw UnZipError.notConnected
                }
                await MainActor.run {
                    session.currentPath = path
                    session.items = items.map(RemoteListingItem.init)
                    self?.busyMessage = nil
                    self?.status = "\(session.bookmark.host)\(path)"
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func downloadAndOpen(_ item: RemoteListingItem, session: FTPSession) {
        let remote = session.joined(item.name)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(item.name)
        busyMessage = "Downloading \(item.name)…"
        progress = 0.2
        let bookmark = session.bookmark
        let client = session.client
        Task.detached { [weak self] in
            do {
                if bookmark.protocolKind == .sftp {
                    try SFTPClient.download(host: bookmark.host, port: bookmark.port, username: bookmark.username, remote: remote, local: local)
                } else if let client {
                    try client.download(path: remote, to: local)
                } else {
                    throw UnZipError.notConnected
                }
                await MainActor.run {
                    self?.progress = nil
                    self?.busyMessage = nil
                    self?.open(url: local)
                }
            } catch {
                await MainActor.run {
                    self?.progress = nil
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func uploadToFTP(local: URL) {
        guard let session = selectedFTP else { return }
        let remote = session.joined(local.lastPathComponent)
        busyMessage = "Uploading \(local.lastPathComponent)…"
        let bookmark = session.bookmark
        let client = session.client
        Task.detached { [weak self] in
            do {
                if bookmark.protocolKind == .sftp {
                    try SFTPClient.upload(host: bookmark.host, port: bookmark.port, username: bookmark.username, local: local, remote: remote)
                } else if let client {
                    try client.upload(local: local, remoteName: remote)
                } else {
                    throw UnZipError.notConnected
                }
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.status = "Uploaded \(local.lastPathComponent)"
                    self?.refreshFTP(session)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshFTP(_ session: FTPSession) {
        let path = session.currentPath
        let bookmark = session.bookmark
        let client = session.client
        Task.detached {
            do {
                let items: [FTPListItem]
                if bookmark.protocolKind == .sftp {
                    items = try SFTPClient.list(host: bookmark.host, port: bookmark.port, username: bookmark.username, path: path)
                } else if let client {
                    items = try client.list()
                } else {
                    return
                }
                await MainActor.run {
                    session.items = items.map(RemoteListingItem.init)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func disconnectFTP(_ session: FTPSession) {
        session.client?.disconnect()
        ftpSessions.removeAll { $0.id == session.id }
        if selectedFTPID == session.id {
            selectedFTPID = ftpSessions.last?.id
        }
        status = "Disconnected."
    }

    func saveBookmark(_ bookmark: FTPBookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else if !bookmarks.contains(where: { $0.host == bookmark.host && $0.username == bookmark.username && $0.protocolKind == bookmark.protocolKind }) {
            bookmarks.insert(bookmark, at: 0)
        }
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }
    }

    func deleteBookmark(_ bookmark: FTPBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }
    }

    func removeRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        defaults.set(recents.map(\.path), forKey: recentsKey)
    }

    func clearRecents() {
        recents = []
        defaults.set([String](), forKey: recentsKey)
        status = "Cleared recent items"
    }

    private func remember(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(12))
        defaults.set(recents.map(\.path), forKey: recentsKey)
    }

    static let archiveTypes: [UTType] = {
        var types: [UTType] = [.zip, .diskImage, .archive]
        let exts = ["rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso", "img", "dmg", "xar", "pkg", "cpio", "cab", "lha", "lzh", "apk", "ipa", "jar"]
        for ext in exts {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()
}

@MainActor
final class FTPSession: Identifiable, ObservableObject {
    let id = UUID()
    let bookmark: FTPBookmark
    var client: FTPClient?
    var password: String = ""
    @Published var currentPath: String
    @Published var items: [RemoteListingItem] = []
    @Published var isConnected = false
    @Published var selectedIDs: Set<String> = []

    init(bookmark: FTPBookmark) {
        self.bookmark = bookmark
        self.currentPath = bookmark.remotePath
    }

    func joined(_ name: String) -> String {
        if currentPath.hasSuffix("/") { return currentPath + name }
        if currentPath.isEmpty || currentPath == "/" { return "/\(name)" }
        return "\(currentPath)/\(name)"
    }
}

struct PasswordPrompt: Identifiable {
    let id = UUID()
    var url: URL
}

struct PreviewContent: Identifiable {
    let id = UUID()
    var name: String
    var kind: Kind
    var text: String?
    var image: NSImage?
    var data: Data

    enum Kind { case text, image, hex, pdf }

    static func make(name: String, data: Data) -> PreviewContent {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let images = Set(["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "icns", "ico", "cur", "avif"])
        if images.contains(ext) || FolderCover.imageExtensions.contains(ext),
           let image = IconFile.nsImage(from: data) {
            return PreviewContent(name: name, kind: .image, text: nil, image: image, data: data)
        }
        if ext == "pdf" {
            return PreviewContent(name: name, kind: .pdf, text: nil, image: nil, data: data)
        }
        let textExts = Set(["txt", "md", "json", "xml", "plist", "swift", "js", "ts", "py", "rb", "sh", "yml", "yaml", "css", "html", "csv", "log", "ini", "conf", "strings", "c", "h", "m", "cpp", "rs", "go", "java", "kt"])
        if textExts.contains(ext), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return PreviewContent(name: name, kind: .text, text: text, image: nil, data: data)
        }
        if data.count < 512_000, let text = String(data: data, encoding: .utf8), text.contains(where: { !$0.isASCII || $0.isLetter || $0.isNewline || $0.isWhitespace }) && !text.contains("\0") {
            return PreviewContent(name: name, kind: .text, text: text, image: nil, data: data)
        }
        return PreviewContent(name: name, kind: .hex, text: hexDump(data), image: nil, data: data)
    }

    private static func hexDump(_ data: Data) -> String {
        let slice = data.prefix(16 * 256)
        var lines: [String] = []
        for start in stride(from: 0, to: slice.count, by: 16) {
            let row = slice[start..<min(start + 16, slice.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = row.map { byte -> String in
                if byte >= 32 && byte < 127 { return String(UnicodeScalar(byte)) }
                return "."
            }.joined()
            lines.append(String(format: "%08X  %-48@  %@", start, hex as NSString, ascii as NSString))
        }
        if data.count > slice.count {
            lines.append("… \(data.count - slice.count) more bytes")
        }
        return lines.joined(separator: "\n")
    }
}

extension RemoteListingItem {
    init(_ item: FTPListItem) {
        self.init(
            id: item.name,
            name: item.name,
            isDirectory: item.isDirectory,
            size: item.size,
            modified: item.modified,
            permissions: item.permissions
        )
    }
}
