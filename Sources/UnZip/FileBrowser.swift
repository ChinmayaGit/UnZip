import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

struct PathCrumb: Identifiable, Hashable {
    var id: Int
    var title: String
    var url: URL
}

struct FileLocation: Identifiable, Hashable {
    var id: String
    var title: String
    var systemImage: String
    var url: URL

    static var home: FileLocation {
        FileLocation(
            id: "home",
            title: "Home",
            systemImage: "house",
            url: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static var favorites: [FileLocation] {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return [
            home,
            FileLocation(id: "desktop", title: "Desktop", systemImage: "menubar.dock.rectangle", url: homeURL.appendingPathComponent("Desktop")),
            FileLocation(id: "documents", title: "Documents", systemImage: "doc", url: homeURL.appendingPathComponent("Documents")),
            FileLocation(id: "downloads", title: "Downloads", systemImage: "arrow.down.circle", url: homeURL.appendingPathComponent("Downloads")),
            FileLocation(id: "pictures", title: "Pictures", systemImage: "photo.on.rectangle", url: homeURL.appendingPathComponent("Pictures")),
            FileLocation(id: "movies", title: "Movies", systemImage: "film", url: homeURL.appendingPathComponent("Movies")),
            FileLocation(id: "music", title: "Music", systemImage: "music.note", url: homeURL.appendingPathComponent("Music")),
            FileLocation(id: "applications", title: "Applications", systemImage: "square.grid.3x3.fill", url: URL(fileURLWithPath: "/Applications"))
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }
}

struct FileItem: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var isPackage: Bool
    var isAlias: Bool
    var size: Int64
    var modified: Date?

    var id: String { url.standardizedFileURL.path }
    var canEnter: Bool { isDirectory && !isPackage }
    var isApplication: Bool {
        if url.pathExtension.lowercased() == "app" { return true }
        if isAlias, resolvedURL.pathExtension.lowercased() == "app" { return true }
        if isPackage, let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .application) {
            return true
        }
        return false
    }
    var isArchive: Bool { !isDirectory && FormatDetector.isUnzippable(url) }
    var isImage: Bool { FolderCover.isImage(url) }
    var isVideo: Bool { !isDirectory && MediaKind.isVideo(url) }
    var isAudio: Bool { !isDirectory && MediaKind.isAudio(url) && !isVideo }

    func displayName(showExtension: Bool) -> String {
        if canEnter || showExtension || url.pathExtension.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }

    func matches(_ filter: KindFilter) -> Bool {
        switch filter {
        case .all: true
        case .folders: canEnter
        case .images: isImage
        case .music: isAudio
        case .videos: isVideo
        case .archives: isArchive
        case .documents: !canEnter && !isImage && !isAudio && !isVideo && !isArchive
        }
    }

    var sizeLabel: String {
        if isDirectory { return "—" }
        return ByteFormat.string(size)
    }

    var kindLabel: String {
        if isPackage { return url.pathExtension.uppercased().isEmpty ? "Package" : url.pathExtension.uppercased() }
        if isDirectory { return "Folder" }
        if isArchive { return ArchiveFormat.from(url: url).displayName }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }

    var dateLabel: String {
        guard let modified else { return "—" }
        return Self.dateFormatter.string(from: modified)
    }

    var systemImage: String {
        if isApplication { return "app.fill" }
        if canEnter { return "folder.fill" }
        if isArchive { return ArchiveFormat.from(url: url).systemImage }
        return FileAppearance.icon(forFileNamed: name)
    }

    var resolvedURL: URL {
        if isAlias, let dest = try? URL(resolvingAliasFileAt: url) {
            return dest
        }
        return url
    }

    init?(url: URL, includeHidden: Bool = false) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isAliasFileKey,
            .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isHidden == true, !includeHidden { return nil }
        self.url = url
        name = url.lastPathComponent
        isDirectory = values?.isDirectory == true
        isPackage = values?.isPackage == true
        isAlias = values?.isAliasFile == true
        size = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
        modified = values?.contentModificationDate
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

enum FolderCover {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jfif", "jif", "gif", "webp",
        "heic", "heif", "tif", "tiff", "bmp", "dib", "ico", "cur", "icns",
        "jp2", "j2k", "jpx", "jpf", "avif", "raw", "cr2", "cr3",
        "nef", "arw", "dng", "orf", "rw2", "raf", "pef", "srw",
        "3fr", "erf", "kdc", "mos", "mrw", "nrw", "x3f", "psd",
        "tga", "exr", "hdr", "pbm", "pgm", "ppm", "pnm"
    ]

    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return true
        }
        return false
    }

    static func firstImage(in folder: URL) -> URL? {
        imageURLs(in: folder).first
    }

    static func imageURLs(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children
            .filter { child in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true { return false }
                return isImage(child)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    nonisolated static func folderCover(at folder: URL) -> CGImage? {
        for url in imageURLs(in: folder) {
            if let image = thumbnail(at: url) {
                return image
            }
        }
        return nil
    }

    nonisolated static func thumbnail(at url: URL, maxPixel: Int = 256) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        if ["ico", "cur"].contains(ext),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let image = IconFile.cgImage(from: data) {
            return image
        }
        if ["ico", "icns", "cur"].contains(ext),
           let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = IconFile.cgImage(from: data) {
                return image
            }
            return NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = IconFile.cgImage(from: data) {
            return image
        }
        return NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

@MainActor
final class FolderCoverStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var requested: Set<String> = []

    func image(for url: URL) -> NSImage? {
        images[url.standardizedFileURL.path]
    }

    func invalidateAll() {
        images.removeAll()
        requested.removeAll()
    }

    func invalidate(_ url: URL) {
        let key = url.standardizedFileURL.path
        images.removeValue(forKey: key)
        requested.remove(key)
    }

    func retryFailed() {
        requested = Set(images.keys)
    }

    func request(_ item: FileItem, appearance: AppearancePreferences) {
        if item.isApplication {
            requestWorkspaceIcon(for: item.url)
            return
        }
        if item.canEnter {
            let style = appearance.coverStyle(for: item.url)
            switch style.mode {
            case .none, .symbol:
                return
            case .custom:
                guard let path = style.imagePath else { return }
                request(item.url, source: URL(fileURLWithPath: path), isDirectoryCover: false)
            case .auto:
                request(item.url, source: item.url, isDirectoryCover: true)
            }
            return
        }
        guard item.isImage else { return }
        request(item.url, source: item.url, isDirectoryCover: false)
    }

    private func requestWorkspaceIcon(for url: URL) {
        let key = url.standardizedFileURL.path
        guard images[key] == nil, !requested.contains(key) else { return }
        requested.insert(key)
        let path = url.path
        Task { @MainActor in
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 256, height: 256)
            trimIfNeeded()
            images[key] = icon
        }
    }

    private func request(_ keyURL: URL, source: URL, isDirectoryCover: Bool) {
        let key = keyURL.standardizedFileURL.path
        guard images[key] == nil, !requested.contains(key) else { return }
        requested.insert(key)
        Task {
            let generated: CGImage? = await Task.detached(priority: .utility) {
                if isDirectoryCover {
                    return FolderCover.folderCover(at: source)
                }
                return FolderCover.thumbnail(at: source)
            }.value
            guard let generated else {
                requested.remove(key)
                return
            }
            trimIfNeeded()
            images[key] = NSImage(cgImage: generated, size: NSSize(width: generated.width, height: generated.height))
        }
    }

    private func trimIfNeeded() {
        guard images.count > 400 else { return }
        for key in images.keys.prefix(images.count - 320) {
            images.removeValue(forKey: key)
            requested.remove(key)
        }
    }
}

@MainActor
final class FileBrowser: ObservableObject {
    @Published var currentURL: URL
    @Published var items: [FileItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var filter: String = ""
    @Published var errorMessage: String?
    @Published var pathHistory: [URL]
    @Published var historyIndex = 0
    @Published var showHidden = false
    var draggingURLs: [URL] = []
    var selectionAnchorID: String?

    let covers = FolderCoverStore()

    private let pathKey = "unzip.fileBrowserPath"
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < pathHistory.count - 1 }
    var canGoUp: Bool {
        currentURL.standardizedFileURL.path != "/"
    }

    var selectedItems: [FileItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var crumbs: [PathCrumb] {
        var urls: [URL] = []
        var url = currentURL.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        while true {
            urls.append(url)
            if url == home || url.path == "/" { break }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent == url { break }
            url = parent
        }
        return urls.reversed().enumerated().map { index, crumb in
            let title: String
            if crumb == home {
                title = "Home"
            } else if crumb.path == "/" {
                title = "Macintosh HD"
            } else {
                title = crumb.lastPathComponent
            }
            return PathCrumb(id: index, title: title, url: crumb)
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: pathKey).map { URL(fileURLWithPath: $0) }
        let start: URL
        if let saved, FileManager.default.fileExists(atPath: saved.path) {
            start = saved
        } else {
            start = FileManager.default.homeDirectoryForCurrentUser
        }
        currentURL = start
        pathHistory = [start]
        reload()
        watch()
    }

    func visibleItems(sort: EntrySort, ascending: Bool, foldersFirst: Bool, kind: KindFilter) -> [FileItem] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var pool = query.isEmpty
            ? items
            : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if kind != .all {
            pool = pool.filter { $0.matches(kind) }
        }
        return pool.sorted { lhs, rhs in
            if foldersFirst, lhs.canEnter != rhs.canEnter { return lhs.canEnter && !rhs.canEnter }
            let ordered: Bool
            switch sort {
            case .name:
                ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date:
                ordered = (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            case .type:
                let typeOrder = lhs.kindLabel.localizedStandardCompare(rhs.kindLabel)
                ordered = typeOrder == .orderedSame
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : typeOrder == .orderedAscending
            case .size:
                ordered = lhs.size == rhs.size
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.size < rhs.size
            }
            return ascending ? ordered : !ordered
        }
    }

    func navigate(to url: URL) {
        let dest = url.standardizedFileURL
        guard dest != currentURL.standardizedFileURL else {
            reload()
            return
        }
        if historyIndex < pathHistory.count - 1 {
            pathHistory = Array(pathHistory.prefix(historyIndex + 1))
        }
        pathHistory.append(dest)
        historyIndex = pathHistory.count - 1
        currentURL = dest
        selectedIDs = []
        filter = ""
        persist()
        reload()
        watch()
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentURL = pathHistory[historyIndex]
        selectedIDs = []
        persist()
        reload()
        watch()
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentURL = pathHistory[historyIndex]
        selectedIDs = []
        persist()
        reload()
        watch()
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    func reload(showHidden: Bool? = nil) {
        if let showHidden {
            self.showHidden = showHidden
        }
        let includeHidden = self.showHidden
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isAliasFileKey,
            .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey
        ]
        do {
            var options: FileManager.DirectoryEnumerationOptions = []
            if !includeHidden {
                options.insert(.skipsHiddenFiles)
            }
            let urls = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: keys,
                options: options
            )
            items = urls.compactMap { FileItem(url: $0, includeHidden: includeHidden) }
            covers.retryFailed()
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    func createFolder() {
        var dest = currentURL.appendingPathComponent("New Folder")
        var index = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = currentURL.appendingPathComponent("New Folder \(index)")
            index += 1
        }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            reload()
            selectedIDs = [dest.standardizedFileURL.path]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persist() {
        UserDefaults.standard.set(currentURL.path, forKey: pathKey)
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = open(currentURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleReload()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        watcher = source
        source.resume()
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
