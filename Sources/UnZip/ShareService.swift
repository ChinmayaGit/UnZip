import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import Network

struct ShareFile: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var size: Int64
    var url: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, size
    }
}

struct NearbyPeer: Identifiable, Hashable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var fileCount: Int

    var isSharing: Bool { fileCount > 0 }

    var pageURL: URL? {
        URL(string: "http://\(host):\(port)/")
    }

    var listURL: URL? {
        URL(string: "http://\(host):\(port)/api/list")
    }

    func downloadURL(for fileID: String) -> URL? {
        URL(string: "http://\(host):\(port)/d/\(fileID)")
    }
}

@MainActor
final class FileShare: ObservableObject {
    @Published var isRunning = false
    @Published var isPublishing = false
    @Published var shareURL: URL?
    @Published var qrImage: NSImage?
    @Published var files: [ShareFile] = []
    @Published var nearby: [NearbyPeer] = []
    @Published var status = "Share is off"
    @Published var receiveNote: String?

    let peerID: String
    let deviceName: String

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var port: UInt16 = 0
    private var fileMap: [String: ShareFile] = [:]

    init() {
        if let saved = UserDefaults.standard.string(forKey: "unzip.peerID") {
            peerID = saved
        } else {
            let created = UUID().uuidString
            UserDefaults.standard.set(created, forKey: "unzip.peerID")
            peerID = created
        }
        deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func start() {
        guard !isRunning else { return }
        startListener()
        startBrowser()
        isRunning = true
        status = "Looking for nearby UnZip…"
    }

    func publish(_ urls: [URL]) {
        start()
        let items = Self.flatten(urls)
        files = items
        fileMap = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        isPublishing = !items.isEmpty
        refreshEndpoint()
        status = items.isEmpty ? "Choose files to share" : "Sharing \(items.count) item\(items.count == 1 ? "" : "s")"
    }

    func stopPublishing() {
        files = []
        fileMap = [:]
        isPublishing = false
        refreshEndpoint()
        status = "Nearby UnZip can still see this Mac"
    }

    func stop() {
        stopPublishing()
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        isRunning = false
        shareURL = nil
        qrImage = nil
        nearby = []
        status = "Share is off"
    }

    func receive(from peer: NearbyPeer, into folder: URL) async throws -> Int {
        guard let listURL = peer.listURL else { throw UnZipError.failed("That device has no share link.") }
        let (data, response) = try await URLSession.shared.data(from: listURL)
        if let http = response as? HTTPURLResponse, http.statusCode == 204 {
            throw UnZipError.failed("\(peer.name) is online but not sharing files yet.")
        }
        let remote = try JSONDecoder().decode([ShareFile].self, from: data)
        var saved = 0
        for file in remote {
            guard let source = peer.downloadURL(for: file.id) else { continue }
            let (temp, _) = try await URLSession.shared.download(from: source)
            let dest = Self.uniqueURL(in: folder, name: URL(fileURLWithPath: file.name).lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: temp, to: dest)
            saved += 1
        }
        return saved
    }

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: deviceName, type: "_unzip-share._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = state {
                        self.port = self.listener?.port?.rawValue ?? 0
                        self.refreshEndpoint()
                    }
                    if case .failed(let error) = state {
                        self.status = error.localizedDescription
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                Task { @MainActor in
                    self?.handle(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = error.localizedDescription
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_unzip-share._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap { NearbyPeer(result: $0) }
            Task { @MainActor in
                guard let self else { return }
                self.nearby = peers.filter { $0.id != self.peerID }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in
                    self?.status = error.localizedDescription
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func refreshEndpoint() {
        guard port > 0, let ip = Self.lanAddresses().first else { return }
        let url = URL(string: "http://\(ip):\(port)/")
        shareURL = url
        if let url {
            qrImage = Self.qrCode(from: url.absoluteString)
        }
        listener?.service = NWListener.Service(
            name: deviceName,
            type: "_unzip-share._tcp",
            txtRecord: NWTXTRecord([
                "peer": peerID,
                "name": deviceName,
                "port": String(port),
                "ips": Self.lanAddresses().joined(separator: ","),
                "count": String(isPublishing ? files.count : 0)
            ])
        )
    }

    private func handle(_ connection: NWConnection) {
        receiveHeader(on: connection, buffer: Data())
    }

    private func receiveHeader(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: next[..<range.lowerBound], as: UTF8.self)
                Task { @MainActor in
                    self?.respond(to: header, on: connection)
                }
                return
            }
            if isComplete || error != nil || next.count > 32_000 {
                connection.cancel()
                return
            }
            Task { @MainActor in
                self?.receiveHeader(on: connection, buffer: next)
            }
        }
    }

    private func respond(to header: String, on connection: NWConnection) {
        let first = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let rawPath = parts.dropFirst().first.map(String.init) ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard method == "GET" else {
            send(on: connection, status: 405, type: "text/plain", body: Data("Method not allowed".utf8))
            return
        }
        if path == "/" || path.isEmpty {
            send(on: connection, status: 200, type: "text/html; charset=utf-8", body: Data(webPage().utf8))
            return
        }
        if path == "/api/peer" {
            let payload = ["name": deviceName, "sharing": isPublishing ? "1" : "0", "count": String(files.count)]
            sendJSON(payload, on: connection)
            return
        }
        if path == "/api/list" {
            if !isPublishing {
                send(on: connection, status: 204, type: "application/json", body: Data())
                return
            }
            sendJSON(files, on: connection)
            return
        }
        if path.hasPrefix("/d/") {
            let id = String(path.dropFirst(3))
            if let file = fileMap[id], let url = file.url, FileManager.default.fileExists(atPath: url.path) {
                sendFile(url, name: URL(fileURLWithPath: file.name).lastPathComponent, on: connection)
                return
            }
            send(on: connection, status: 404, type: "text/plain", body: Data("Missing".utf8))
            return
        }
        send(on: connection, status: 404, type: "text/plain", body: Data("Not found".utf8))
    }

    private func sendJSON<T: Encodable>(_ value: T, on connection: NWConnection) {
        let data = (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
        send(on: connection, status: 200, type: "application/json", body: data)
    }

    private func send(on connection: NWConnection, status: Int, type: String, body: Data) {
        let reason = status == 200 ? "OK" : status == 204 ? "No Content" : status == 404 ? "Not Found" : "Error"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendFile(_ url: URL, name: String, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            send(on: connection, status: 404, type: "text/plain", body: Data("Missing".utf8))
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let escaped = name.replacingOccurrences(of: "\"", with: "")
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/octet-stream\r\n"
        header += "Content-Disposition: attachment; filename=\"\(escaped)\"\r\n"
        header += "Content-Length: \(size)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            Self.stream(handle, on: connection)
        })
    }

    private static func stream(_ handle: FileHandle, on connection: NWConnection) {
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            stream(handle, on: connection)
        })
    }

    private func webPage() -> String {
        let items = files.map { file in
            let safe = Self.escape(file.name)
            return """
            <a class="file" href="/d/\(file.id)"><strong>\(safe)</strong><span>\(ByteFormat.string(file.size))</span></a>
            """
        }.joined()
        let list = items.isEmpty
            ? "<p class=\"empty\">This Mac is online with UnZip. Ask them to tap Share on the files they want to send.</p>"
            : items
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>UnZip Share</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;background:#0f1115;color:#f2f4f8}
        main{max-width:560px;margin:0 auto;padding:28px 20px 48px}
        h1{font-size:28px;margin:0 0 6px}
        .sub{color:#9aa3b2;margin:0 0 22px}
        .card{background:#1a1f27;border-radius:16px;padding:16px;display:flex;flex-direction:column;gap:10px}
        .file{display:flex;justify-content:space-between;gap:12px;padding:12px 14px;border-radius:12px;background:#262c36;color:#fff;text-decoration:none}
        .file span{color:#9aa3b2}
        .empty{color:#9aa3b2}
        .hint{margin-top:22px;color:#9aa3b2;font-size:14px;line-height:1.45}
        </style></head>
        <body><main>
        <h1>UnZip Share</h1>
        <p class="sub">From \(Self.escape(deviceName))</p>
        <div class="card">\(list)</div>
        <p class="hint">You don’t need the UnZip app to download. Tap a file to save it. If you want nearby-device sharing next time, install UnZip on this device.</p>
        </main></body></html>
        """
    }

    static func qrCode(from string: String, dimension: CGFloat = 280) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: dimension, height: dimension))
        image.addRepresentation(rep)
        return image
    }

    static func flatten(_ urls: [URL]) -> [ShareFile] {
        var items: [ShareFile] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                let children = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                while let child = children?.nextObject() as? URL {
                    let childValues = try? child.resourceValues(forKeys: keys)
                    if childValues?.isDirectory == true { continue }
                    let rel = child.path.replacingOccurrences(of: url.deletingLastPathComponent().path + "/", with: "")
                    items.append(ShareFile(id: UUID().uuidString, name: rel, size: Int64(childValues?.fileSize ?? 0), url: child))
                    if items.count >= 400 { return items }
                }
            } else {
                items.append(ShareFile(id: UUID().uuidString, name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0), url: url))
            }
            if items.count >= 400 { break }
        }
        return items
    }

    static func lanAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") { addresses.append(ip) }
        }
        return addresses
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
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

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension NearbyPeer {
    init?(result: NWBrowser.Result) {
        var record: NWTXTRecord?
        if case .bonjour(let txt) = result.metadata {
            record = txt
        }
        let txt = record
        let id = txt?["peer"] ?? result.endpoint.debugDescription
        let name = txt?["name"] ?? {
            if case .service(let serviceName, _, _, _) = result.endpoint { return serviceName }
            return "UnZip"
        }()
        let port = Int(txt?["port"] ?? "") ?? 0
        let hosts = (txt?["ips"] ?? "").split(separator: ",").map(String.init)
        guard port > 0, let host = hosts.first else { return nil }
        self.init(id: id, name: name, host: host, port: port, fileCount: Int(txt?["count"] ?? "0") ?? 0)
    }
}
