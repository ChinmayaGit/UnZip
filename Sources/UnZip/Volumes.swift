import AppKit
import Combine
import Foundation

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

@MainActor
final class VolumeStore: ObservableObject {
    @Published private(set) var volumes: [MountedVolume] = []

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
}
