import AppKit
import UniformTypeIdentifiers

enum DroppedFiles {
    static func urls(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var urls: [URL] = []
        }
        let group = DispatchGroup()
        let box = Box()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let value = item as? NSURL {
                    url = value as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                if let url {
                    box.lock.lock()
                    box.urls.append(url)
                    box.lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            completion(box.urls)
        }
    }
}
