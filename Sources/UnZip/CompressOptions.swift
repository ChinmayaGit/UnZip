import Foundation

enum CompressFormat: String, CaseIterable, Identifiable, Sendable {
    case zip, rar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .rar: "RAR"
        }
    }

    var fileExtension: String { rawValue }

    var isAvailable: Bool {
        switch self {
        case .zip: true
        case .rar: Toolchain.rar != nil
        }
    }
}

enum StoreMethod: String, CaseIterable, Identifiable, Sendable {
    case high, medium, low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    var subtitle: String {
        switch self {
        case .high: "More time, smallest size"
        case .medium: "Less time, balanced"
        case .low: "Storing, no compression"
        }
    }

    var zipFlag: String {
        switch self {
        case .high: "-9"
        case .medium: "-6"
        case .low: "-0"
        }
    }

    var rarMethod: String {
        switch self {
        case .high: "-m5"
        case .medium: "-m3"
        case .low: "-m0"
        }
    }

    var sevenZipLevel: String {
        switch self {
        case .high: "-mx=9"
        case .medium: "-mx=5"
        case .low: "-mx=0"
        }
    }
}

enum SplitPreset: String, CaseIterable, Identifiable, Sendable {
    case none, mb50, mb100, mb200, mb500, gb1, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Don't split"
        case .mb50: "50 MB parts"
        case .mb100: "100 MB parts"
        case .mb200: "200 MB parts"
        case .mb500: "500 MB parts"
        case .gb1: "1 GB parts"
        case .custom: "Custom size…"
        }
    }

    var bytes: Int64? {
        switch self {
        case .none: 0
        case .mb50: 50 * 1_000_000
        case .mb100: 100 * 1_000_000
        case .mb200: 200 * 1_000_000
        case .mb500: 500 * 1_000_000
        case .gb1: 1_000_000_000
        case .custom: nil
        }
    }
}

struct CompressOptions: Sendable {
    var format: CompressFormat
    var method: StoreMethod
    var split: SplitPreset
    var customSplitMB: Int

    init(format: CompressFormat = .zip, method: StoreMethod = .medium, split: SplitPreset = .none, customSplitMB: Int = 200) {
        self.format = format
        self.method = method
        self.split = split
        self.customSplitMB = customSplitMB
    }

    var splitBytes: Int64 {
        if split == .custom {
            return Int64(max(1, customSplitMB)) * 1_000_000
        }
        return split.bytes ?? 0
    }

    var zipSplitToken: String? {
        guard splitBytes > 0 else { return nil }
        let mb = max(1, splitBytes / 1_000_000)
        return "\(mb)m"
    }
}

struct CompressJob: Identifiable, Sendable {
    let id = UUID()
    var format: CompressFormat
    var suggestedName: String
    var origin: Origin

    enum Origin: Sendable {
        case local([URL])
        case archive(documentID: UUID, entries: [ArchiveEntry])
    }

    var documentID: UUID? {
        if case .archive(let id, _) = origin { return id }
        return nil
    }
}

struct DropOffer: Identifiable {
    let id = UUID()
    var archives: [URL]
    var packable: [URL]

    var title: String {
        if packable.count == 1 {
            return packable[0].lastPathComponent
        }
        return "\(packable.count) items"
    }

    var isFolderDrop: Bool {
        packable.count == 1 && FormatDetector.isDirectory(packable[0])
    }
}
