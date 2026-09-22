import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark, midnight, warm, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .midnight: "Midnight"
        case .warm: "Warm"
        case .graphite: "Graphite"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .warm: .light
        case .dark, .midnight, .graphite: .dark
        }
    }

    var accent: Color {
        switch self {
        case .system: .accentColor
        case .light: Color(red: 0.20, green: 0.48, blue: 0.96)
        case .dark: Color(red: 0.40, green: 0.68, blue: 1.00)
        case .midnight: Color(red: 0.45, green: 0.55, blue: 1.00)
        case .warm: Color(red: 0.86, green: 0.42, blue: 0.22)
        case .graphite: Color(red: 0.72, green: 0.74, blue: 0.78)
        }
    }

    var windowBackground: Color {
        switch self {
        case .midnight: Color(red: 0.07, green: 0.09, blue: 0.16)
        case .warm: Color(red: 0.98, green: 0.95, blue: 0.90)
        case .graphite: Color(red: 0.14, green: 0.15, blue: 0.17)
        default: Color(nsColor: .windowBackgroundColor)
        }
    }
}

enum CoverMode: String, CaseIterable, Identifiable, Codable {
    case auto, none, custom, symbol

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "First image"
        case .none: "Folder icon"
        case .custom: "Custom image"
        case .symbol: "Custom icon"
        }
    }
}

enum CoverFit: String, CaseIterable, Identifiable, Codable {
    case crop, fit, fitWidth, fitHeight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: "Crop"
        case .fit: "Fit"
        case .fitWidth: "Fit width"
        case .fitHeight: "Fit height"
        }
    }

    var subtitle: String {
        switch self {
        case .crop: "Fill the tile and crop overflow"
        case .fit: "Show the whole image"
        case .fitWidth: "Match the tile width"
        case .fitHeight: "Match the tile height"
        }
    }
}

enum KindFilter: String, CaseIterable, Identifiable, Codable {
    case all, folders, images, music, videos, archives, documents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .folders: "Folders"
        case .images: "Images"
        case .music: "Music"
        case .videos: "Videos"
        case .archives: "Archives"
        case .documents: "Documents"
        }
    }
}

struct CoverStyle: Codable, Equatable, Hashable {
    var mode: CoverMode = .auto
    var fit: CoverFit = .crop
    var imagePath: String?
    var symbol: String?

    var resolvedSymbol: String {
        symbol?.isEmpty == false ? symbol! : "folder.fill"
    }
}

enum MediaKind {
    static let audioExtensions: Set<String> = [
        "mp3", "wav", "aiff", "aif", "m4a", "aac", "flac", "ogg", "oga", "wma",
        "opus", "alac", "caf", "au", "snd", "amr", "mid", "midi", "mp2", "mpga",
        "mka", "weba", "ac3", "eac3", "aifc", "m4b", "m4r"
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "mpg", "mpeg", "m2v",
        "m4p", "3gp", "3g2", "flv", "ts", "m2ts", "vob", "ogv", "asf", "f4v",
        "mts", "m2t", "qt"
    ]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func isAudio(_ url: URL) -> Bool {
        !isVideo(url) && audioExtensions.contains(url.pathExtension.lowercased())
    }
}

@MainActor
final class AppearancePreferences: ObservableObject {
    @Published var theme: AppTheme {
        didSet { persist() }
    }
    @Published var globalCover: CoverStyle {
        didSet { persist() }
    }
    @Published var enabledLayouts: [BrowserLayout] {
        didSet { persist() }
    }
    @Published var iconScale: Double {
        didSet { persist() }
    }
    @Published var showHidden: Bool {
        didSet { persist() }
    }
    @Published var foldersFirst: Bool {
        didSet { persist() }
    }
    @Published var showExtensions: Bool {
        didSet { persist() }
    }
    @Published var kindFilter: KindFilter {
        didSet { persist() }
    }
    @Published var defaultFolderSymbol: String {
        didSet { persist() }
    }
    @Published var folderOverrides: [String: CoverStyle] {
        didSet { persist() }
    }
    @Published var musicBarHeight: Double {
        didSet { persist() }
    }

    private let defaults = UserDefaults.standard
    private let key = "unzip.appearance.v1"

    static let folderSymbols = [
        "folder.fill", "folder", "folder.badge.plus", "internaldrive",
        "externaldrive.fill", "photo.on.rectangle", "music.note.house.fill",
        "film.fill", "archivebox.fill", "shippingbox.fill", "book.fill",
        "star.fill", "heart.fill", "leaf.fill", "flame.fill", "sparkles",
        "paintpalette.fill", "theatermasks.fill", "gamecontroller.fill"
    ]

    init() {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            theme = saved.theme
            globalCover = saved.globalCover
            enabledLayouts = saved.enabledLayouts.isEmpty ? BrowserLayout.defaultVisible : saved.enabledLayouts
            iconScale = min(2.0, max(0.6, saved.iconScale))
            showHidden = saved.showHidden
            foldersFirst = saved.foldersFirst
            showExtensions = saved.showExtensions
            kindFilter = saved.kindFilter
            defaultFolderSymbol = saved.defaultFolderSymbol
            folderOverrides = saved.folderOverrides
            musicBarHeight = min(140, max(64, saved.musicBarHeight ?? 88))
        } else {
            theme = .system
            globalCover = CoverStyle()
            enabledLayouts = BrowserLayout.defaultVisible
            iconScale = 1.0
            showHidden = false
            foldersFirst = true
            showExtensions = true
            kindFilter = .all
            defaultFolderSymbol = "folder.fill"
            folderOverrides = [:]
            musicBarHeight = 88
        }
    }

    var visibleLayouts: [BrowserLayout] {
        let known = enabledLayouts.filter { BrowserLayout.allCases.contains($0) }
        return known.isEmpty ? BrowserLayout.defaultVisible : known
    }

    func isLayoutEnabled(_ layout: BrowserLayout) -> Bool {
        visibleLayouts.contains(layout)
    }

    func toggleLayout(_ layout: BrowserLayout) {
        if let index = enabledLayouts.firstIndex(of: layout) {
            if enabledLayouts.count > 1 {
                enabledLayouts.remove(at: index)
            }
        } else {
            enabledLayouts.append(layout)
        }
    }

    func coverStyle(for folder: URL) -> CoverStyle {
        folderOverrides[folder.standardizedFileURL.path] ?? globalCover
    }

    func setCover(_ style: CoverStyle, for folder: URL?, applyGlobally: Bool) {
        if applyGlobally || folder == nil {
            globalCover = style
        }
        if let folder {
            folderOverrides[folder.standardizedFileURL.path] = style
        }
    }

    func clearCover(for folder: URL) {
        folderOverrides.removeValue(forKey: folder.standardizedFileURL.path)
    }

    func iconSize(for layout: BrowserLayout) -> CGFloat {
        let scale = iconScale
        switch layout {
        case .details: return 20
        case .list: return 28 * scale
        case .grid: return 72 * scale
        case .large: return 118 * scale
        case .extraLarge: return 168 * scale
        case .tiles: return 68 * scale
        case .gallery: return 188 * scale
        }
    }

    func tileWidth(for layout: BrowserLayout) -> CGFloat {
        switch layout {
        case .details, .list, .tiles: return 0
        case .grid: return max(108, iconSize(for: .grid) + 36)
        case .large: return max(148, iconSize(for: .large) + 40)
        case .extraLarge: return max(196, iconSize(for: .extraLarge) + 44)
        case .gallery: return max(220, iconSize(for: .gallery) + 32)
        }
    }

    func importCoverImage() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = Self.imageTypes
        panel.title = "Pick Image from Anywhere"
        panel.prompt = "Use Image"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Self.copyCover(from: url)
    }

    static func copyCover(from url: URL) -> String? {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("UnZip/covers", isDirectory: true)
        guard let folder else { return url.path }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return dest.path
        } catch {
            return url.path
        }
    }

    static let imageTypes: [UTType] = {
        var types: [UTType] = [.image]
        for ext in ["ico", "icns", "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "bmp"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()

    private struct Snapshot: Codable {
        var theme: AppTheme
        var globalCover: CoverStyle
        var enabledLayouts: [BrowserLayout]
        var iconScale: Double
        var showHidden: Bool
        var foldersFirst: Bool
        var showExtensions: Bool
        var kindFilter: KindFilter
        var defaultFolderSymbol: String
        var folderOverrides: [String: CoverStyle]
        var musicBarHeight: Double?
    }

    private func persist() {
        let snapshot = Snapshot(
            theme: theme,
            globalCover: globalCover,
            enabledLayouts: enabledLayouts,
            iconScale: iconScale,
            showHidden: showHidden,
            foldersFirst: foldersFirst,
            showExtensions: showExtensions,
            kindFilter: kindFilter,
            defaultFolderSymbol: defaultFolderSymbol,
            folderOverrides: folderOverrides,
            musicBarHeight: musicBarHeight
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
    }
}
