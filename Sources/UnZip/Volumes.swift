import AppKit
import Combine
import Foundation
import SwiftUI

struct MountedVolume: Identifiable, Hashable {
    var url: URL
    var name: String
    var systemImage: String
    var isEjectable: Bool

    var id: String { url.standardizedFileURL.path }

    func contains(_ other: URL) -> Bool {
        let root = url.standardizedFileURL.path
        let path = other.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
}

struct VolumeUsage: Identifiable, Hashable {
    var url: URL
    var name: String
    var systemImage: String
    var totalBytes: Int64
    var freeBytes: Int64
    var isEjectable: Bool

    var id: String { url.standardizedFileURL.path }
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    var percentLabel: String {
        "\(Int((usedFraction * 100).rounded()))%"
    }
}

struct StorageMeter: View {
    let usage: VolumeUsage
    var compact: Bool = false
    var onOpen: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                Image(systemName: usage.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(usage.name)
                    .font(compact ? .caption.weight(.medium) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(usage.percentLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(usage.usedFraction > 0.9 ? Color.red : Color.accentColor)
                        .frame(width: max(6, geo.size.width * usage.usedFraction))
                }
            }
            .frame(height: compact ? 5 : 8)
            Text("\(ByteFormat.string(usage.freeBytes)) free of \(ByteFormat.string(usage.totalBytes))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(compact ? 8 : 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .help("\(usage.name): \(ByteFormat.string(usage.usedBytes)) used")
    }
}

@MainActor
final class VolumeStore: ObservableObject {
    @Published private(set) var volumes: [MountedVolume] = []
    @Published private(set) var storage: [VolumeUsage] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        volumes = Self.scan()
        storage = Self.scanStorage()
    }

    func volume(containing url: URL) -> MountedVolume? {
        volumes.first { $0.contains(url) }
    }

    private static func scan() -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey
        ]
        var seen = Set<String>()
        var found: [MountedVolume] = []

        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        let extras = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in mounted + extras {
            guard let volume = makeVolume(url, keys: keys) else { continue }
            guard seen.insert(volume.id).inserted else { continue }
            found.append(volume)
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func makeVolume(_ url: URL, keys: Set<URLResourceKey>) -> MountedVolume? {
        let values = try? url.resourceValues(forKeys: keys)
        if values?.volumeIsRootFileSystem == true { return nil }
        if values?.volumeIsBrowsable == false { return nil }
        let path = url.standardizedFileURL.path
        if path == "/" { return nil }

        let removable = values?.volumeIsRemovable ?? false
        let ejectable = values?.volumeIsEjectable ?? removable
        let internalDisk = values?.volumeIsInternal ?? true
        let local = values?.volumeIsLocal ?? true
        if internalDisk, !removable, local {
            return nil
        }

        let name = values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent
        let icon: String
        if !local {
            icon = "externaldrive.badge.wifi"
        } else if removable {
            icon = "sdcard"
        } else {
            icon = "externaldrive.fill"
        }
        return MountedVolume(url: url.standardizedFileURL, name: name, systemImage: icon, isEjectable: ejectable || removable)
    }

    private static func scanStorage() -> [VolumeUsage] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        var seen = Set<String>()
        var found: [VolumeUsage] = []
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        for url in mounted {
            guard let usage = makeUsage(url, keys: keys) else { continue }
            guard seen.insert(usage.id).inserted else { continue }
            found.append(usage)
        }
        return found.sorted { left, right in
            let leftRoot = left.url.path == "/"
            let rightRoot = right.url.path == "/"
            if leftRoot != rightRoot { return leftRoot }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private static func makeUsage(_ url: URL, keys: Set<URLResourceKey>) -> VolumeUsage? {
        let values = try? url.resourceValues(forKeys: keys)
        if values?.volumeIsBrowsable == false { return nil }
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        guard total > 0 else { return nil }
        let important = values?.volumeAvailableCapacityForImportantUsage
        let available = values?.volumeAvailableCapacity.map { Int64($0) }
        let free = important ?? available ?? 0
        let removable = values?.volumeIsRemovable ?? false
        let ejectable = values?.volumeIsEjectable ?? removable
        let local = values?.volumeIsLocal ?? true
        let root = values?.volumeIsRootFileSystem == true || url.standardizedFileURL.path == "/"
        let name = values?.volumeLocalizedName ?? values?.volumeName ?? (root ? "Macintosh HD" : url.lastPathComponent)
        let icon: String
        if root {
            icon = "internaldrive"
        } else if !local {
            icon = "externaldrive.badge.wifi"
        } else if removable {
            icon = "sdcard"
        } else {
            icon = "externaldrive.fill"
        }
        return VolumeUsage(
            url: url.standardizedFileURL,
            name: name,
            systemImage: icon,
            totalBytes: total,
            freeBytes: max(0, free),
            isEjectable: ejectable || removable
        )
    }
}
