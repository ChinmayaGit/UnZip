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

    var previewKind: String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if FolderCover.imageExtensions.contains(ext) { return "image" }
        if MediaKind.isVideo(URL(fileURLWithPath: name)) { return "video" }
        if MediaKind.isAudio(URL(fileURLWithPath: name)) { return "audio" }
        return "file"
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
        if path.hasPrefix("/d/") || path.hasPrefix("/p/") {
            let id = String(path.dropFirst(3))
            if let file = fileMap[id], let url = file.url, FileManager.default.fileExists(atPath: url.path) {
                sendFile(
                    url,
                    name: URL(fileURLWithPath: file.name).lastPathComponent,
                    inline: path.hasPrefix("/p/"),
                    requestHeader: header,
                    on: connection
                )
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

    private func sendFile(_ url: URL, name: String, inline: Bool, requestHeader: String, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            send(on: connection, status: 404, type: "text/plain", body: Data("Missing".utf8))
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let escaped = name.replacingOccurrences(of: "\"", with: "")
        let type = Self.mimeType(for: name)
        let range = Self.byteRange(from: requestHeader, size: size)
        let start = range?.0 ?? 0
        let end = range?.1 ?? max(size - 1, 0)
        let length = size == 0 ? 0 : (end - start + 1)
        if start > 0 {
            try? handle.seek(toOffset: UInt64(start))
        }
        var header = range == nil ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Disposition: \(inline ? "inline" : "attachment"); filename=\"\(escaped)\"\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if range != nil {
            header += "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        }
        header += "Content-Length: \(length)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            Self.stream(handle, remaining: length, on: connection)
        })
    }

    nonisolated private static func stream(_ handle: FileHandle, remaining: Int, on connection: NWConnection) {
        if remaining <= 0 {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let chunk = handle.readData(ofLength: min(64 * 1024, remaining))
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
            stream(handle, remaining: remaining - chunk.count, on: connection)
        })
    }

    private func webPage() -> String {
        struct PageFile: Encodable {
            var id: String
            var name: String
            var size: Int64
            var kind: String
            var ext: String
        }
        let items = files.map { file in
            PageFile(
                id: file.id,
                name: file.name,
                size: file.size,
                kind: file.previewKind,
                ext: URL(fileURLWithPath: file.name).pathExtension.lowercased()
            )
        }
        let json = String(data: (try? JSONEncoder().encode(items)) ?? Data("[]".utf8), encoding: .utf8)?
            .replacingOccurrences(of: "<", with: "\\u003c") ?? "[]"
        return """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>UnZip Share</title>
        <style>
        :root{--bg:#0f1115;--panel:#1a1f27;--line:#2a3140;--text:#f2f4f8;--muted:#9aa3b2;--accent:#7cb8ff;--pick:#4d8dff;--cell:132px;--scale:1}
        *{box-sizing:border-box}
        html,body{margin:0;min-height:100%;background:var(--bg);color:var(--text);font:15px/1.4 -apple-system,BlinkMacSystemFont,Helvetica,sans-serif}
        body{display:flex;flex-direction:column}
        header{position:sticky;top:0;z-index:5;background:rgba(15,17,21,.94);backdrop-filter:blur(14px);border-bottom:1px solid var(--line);padding:16px 22px 12px}
        h1{font-size:22px;margin:0}
        .sub{color:var(--muted);margin:4px 0 12px;font-size:13px}
        .toolbar{display:flex;flex-wrap:wrap;gap:10px;align-items:center}
        .views{display:flex;flex-wrap:wrap;gap:4px;padding:3px;background:#141820;border:1px solid var(--line);border-radius:10px}
        .views button,.ctrl button{appearance:none;border:0;background:transparent;color:var(--text);padding:6px 10px;border-radius:7px;cursor:pointer;font:13px/1.2 inherit}
        .views button.on{background:rgba(77,141,255,.22);color:#dbe8ff}
        .ctrl{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:13px}
        .ctrl input[type=range]{width:110px;accent-color:var(--pick)}
        .ctrl select,.ctrl input[type=search]{background:#141820;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:6px 8px;font:13px inherit}
        .ctrl input[type=search]{width:min(220px,40vw)}
        .grow{flex:1}
        main{flex:1;padding:16px 22px 40px}
        .empty{color:var(--muted);max-width:520px;margin:40px auto;text-align:center}
        table{width:100%;border-collapse:collapse}
        th{text-align:left;font-size:12px;color:var(--muted);font-weight:600;padding:8px 10px;border-bottom:1px solid var(--line);position:sticky;top:118px;background:var(--bg)}
        td{padding:8px 10px;border-bottom:1px solid #1d232d;vertical-align:middle}
        tr{cursor:pointer}
        tr:hover td{background:#171c24}
        tr.on td{background:rgba(77,141,255,.18)}
        .name{display:flex;align-items:center;gap:10px;min-width:0}
        .name span,.tile-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .muted{color:var(--muted)}
        a.dl{color:var(--accent);text-decoration:none;font-size:13px}
        a.dl:hover{text-decoration:underline}
        .rows{display:flex;flex-direction:column;gap:2px}
        .row{display:flex;align-items:center;gap:12px;padding:8px 10px;border-radius:10px;cursor:pointer}
        .row:hover{background:#171c24}
        .row.on{background:rgba(77,141,255,.2)}
        .row .size{margin-left:auto;color:var(--muted);font-variant-numeric:tabular-nums}
        .tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(calc(var(--cell)*var(--scale)),1fr));gap:14px}
        .tile{display:flex;flex-direction:column;align-items:center;gap:8px;padding:10px 8px 12px;border-radius:16px;cursor:pointer;min-width:0}
        .tile:hover{background:#171c24}
        .tile.on{background:rgba(77,141,255,.2);box-shadow:inset 0 0 0 2px rgba(124,184,255,.7)}
        .tile-name{width:100%;text-align:center;font-size:12px}
        .glyph{width:calc(28px*var(--scale));height:calc(28px*var(--scale));border-radius:8px;display:grid;place-items:center;background:#262c36;flex:none;overflow:hidden;position:relative}
        table .glyph,.rows .glyph{width:calc(28px*var(--scale));height:calc(28px*var(--scale))}
        .tiles .glyph{width:calc(var(--cell)*var(--scale) - 36px);height:calc(var(--cell)*var(--scale) - 36px);border-radius:14px;background:#11151c}
        .glyph img{width:100%;height:100%;object-fit:cover;display:block}
        .glyph.video{background:#0b0d12}
        .glyph .mark{position:absolute;inset:auto auto 8px 8px;background:rgba(0,0,0,.55);color:#fff;border-radius:8px;padding:3px 7px;font-size:11px}
        .kind-video::after,.kind-audio::after,.kind-file::after{position:absolute;font-size:22px;color:#fff}
        .kind-video::after{content:"▶"}
        .kind-audio::after{content:"♪";color:#c9d4e5}
        .kind-file::after{content:"▢";color:#9aa3b2;font-size:20px}
        dialog{border:0;padding:0;background:transparent;max-width:none;width:min(960px,94vw)}
        dialog::backdrop{background:rgba(0,0,0,.72)}
        .preview{background:var(--panel);border-radius:16px;overflow:hidden;box-shadow:0 24px 60px rgba(0,0,0,.45)}
        .preview-bar{display:flex;gap:12px;align-items:center;padding:12px 14px;border-bottom:1px solid var(--line)}
        .preview-bar button{appearance:none;border:0;background:#262c36;color:var(--text);padding:6px 10px;border-radius:8px;cursor:pointer;font:13px inherit}
        .preview-bar strong{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .preview-body{background:#000;min-height:120px;display:grid;place-items:center}
        .preview-body img,.preview-body video{max-width:100%;max-height:min(70vh,720px);display:block}
        .preview-body audio{width:min(520px,90%);margin:36px}
        .preview-body .none{color:var(--muted);padding:40px 20px;text-align:center}
        .hint{margin:22px 22px 0;color:var(--muted);font-size:13px}
        @media(max-width:720px){
          header,main{padding-left:14px;padding-right:14px}
          .ctrl.desk{display:none}
          th{top:0;position:static}
        }
        </style>
        </head>
        <body>
        <header>
          <h1>UnZip Share</h1>
          <p class="sub">From \(Self.escape(deviceName)) — browse like a file list, then play or download.</p>
          <div class="toolbar">
            <div class="views" id="views">
              <button data-view="details">Details</button>
              <button data-view="list">List</button>
              <button data-view="grid">Grid</button>
              <button data-view="large">Large</button>
            </div>
            <label class="ctrl desk">Size <input id="size" type="range" min="70" max="180" value="100"></label>
            <label class="ctrl">Filter
              <select id="filter">
                <option value="all">All</option>
                <option value="image">Photos</option>
                <option value="video">Videos</option>
                <option value="audio">Music</option>
                <option value="file">Files</option>
              </select>
            </label>
            <label class="ctrl">Sort
              <select id="sort">
                <option value="name">Name</option>
                <option value="size">Size</option>
                <option value="kind">Kind</option>
              </select>
            </label>
            <button class="ctrl" id="dir" type="button" title="Sort direction">↑</button>
            <span class="grow"></span>
            <label class="ctrl"><input id="q" type="search" placeholder="Search"></label>
          </div>
        </header>
        <main id="main"></main>
        <p class="hint">You don’t need UnZip on this device. Open a photo, video, or song to play it, or download any file.</p>
        <dialog id="dlg">
          <div class="preview">
            <div class="preview-bar">
              <button type="button" id="prev" title="Previous">‹</button>
              <strong id="pname"></strong>
              <button type="button" id="next" title="Next">›</button>
              <a class="dl" id="pdl" href="#">Download</a>
              <button type="button" id="close">Close</button>
            </div>
            <div class="preview-body" id="pbody"></div>
          </div>
        </dialog>
        <script>
        const FILES = \(json);
        const store = window.localStorage;
        const desktop = window.matchMedia("(min-width: 720px)").matches;
        let view = store.getItem("unzip.share.view") || (desktop ? "grid" : "list");
        let scale = Number(store.getItem("unzip.share.scale") || 100);
        let filter = "all";
        let sort = "name";
        let dir = 1;
        let selected = "";
        let shown = [];
        const main = document.getElementById("main");
        const size = document.getElementById("size");
        const dlg = document.getElementById("dlg");
        size.value = String(scale);
        document.getElementById("filter").onchange = function(){ filter = this.value; draw(); };
        document.getElementById("sort").onchange = function(){ sort = this.value; draw(); };
        document.getElementById("q").oninput = function(){ draw(); };
        document.getElementById("dir").onclick = function(){ dir *= -1; this.textContent = dir > 0 ? "↑" : "↓"; draw(); };
        size.oninput = function(){ scale = Number(this.value); store.setItem("unzip.share.scale", String(scale)); applyScale(); };
        document.getElementById("views").onclick = function(e){
          const b = e.target.closest("button");
          if (!b) return;
          view = b.getAttribute("data-view");
          store.setItem("unzip.share.view", view);
          draw();
        };
        document.getElementById("close").onclick = function(){ closePreview(); };
        document.getElementById("prev").onclick = function(){ step(-1); };
        document.getElementById("next").onclick = function(){ step(1); };
        dlg.addEventListener("close", closePreview);
        document.addEventListener("keydown", function(e){
          if (!dlg.open) return;
          if (e.key === "ArrowRight") step(1);
          if (e.key === "ArrowLeft") step(-1);
          if (e.key === "Escape") closePreview();
        });
        function applyScale(){
          document.documentElement.style.setProperty("--scale", String(scale / 100));
          document.documentElement.style.setProperty("--cell", view === "large" ? "196px" : "132px");
        }
        function kindLabel(k){ return k === "image" ? "Photo" : k === "video" ? "Video" : k === "audio" ? "Music" : "File"; }
        function bytes(n){
          if (n < 1024) return n + " B";
          const u = ["KB","MB","GB","TB"];
          let i = -1; let v = n;
          do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
          return (v < 10 ? v.toFixed(1) : Math.round(v)) + " " + u[i];
        }
        function glyph(file){
          const box = document.createElement("div");
          box.className = "glyph kind-" + file.kind + (file.kind === "video" ? " video" : "");
          if (file.kind === "image") {
            const img = document.createElement("img");
            img.src = "/p/" + file.id;
            img.alt = "";
            img.loading = "lazy";
            box.appendChild(img);
          }
          if (file.kind === "video") {
            const mark = document.createElement("span");
            mark.className = "mark";
            mark.textContent = "Video";
            box.appendChild(mark);
          }
          return box;
        }
        function visible(){
          const q = document.getElementById("q").value.trim().toLowerCase();
          const rows = FILES.filter(function(f){
            if (filter !== "all" && f.kind !== filter) return false;
            return !q || f.name.toLowerCase().indexOf(q) !== -1;
          });
          rows.sort(function(a,b){
            let c = 0;
            if (sort === "size") c = a.size - b.size;
            else if (sort === "kind") c = a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name);
            else c = a.name.localeCompare(b.name);
            return c * dir;
          });
          return rows;
        }
        function openFile(file){
          selected = file.id;
          highlight();
          document.getElementById("pname").textContent = file.name;
          const link = document.getElementById("pdl");
          link.href = "/d/" + file.id;
          const body = document.getElementById("pbody");
          body.replaceChildren();
          if (file.kind === "image") {
            const img = document.createElement("img");
            img.src = "/p/" + file.id;
            img.alt = file.name;
            body.appendChild(img);
          } else if (file.kind === "video") {
            const v = document.createElement("video");
            v.controls = true;
            v.autoplay = true;
            v.playsInline = true;
            v.src = "/p/" + file.id;
            body.appendChild(v);
          } else if (file.kind === "audio") {
            const a = document.createElement("audio");
            a.controls = true;
            a.autoplay = true;
            a.src = "/p/" + file.id;
            body.appendChild(a);
          } else {
            const p = document.createElement("div");
            p.className = "none";
            p.textContent = "No preview for this file. Use Download.";
            body.appendChild(p);
          }
          if (!dlg.open) dlg.showModal();
        }
        function closePreview(){
          document.getElementById("pbody").replaceChildren();
          if (dlg.open) dlg.close();
        }
        function step(delta){
          if (!shown.length) return;
          let i = shown.findIndex(function(f){ return f.id === selected; });
          if (i < 0) i = 0;
          i = (i + delta + shown.length) % shown.length;
          openFile(shown[i]);
        }
        function highlight(){
          main.querySelectorAll("[data-id]").forEach(function(el){
            el.classList.toggle("on", el.getAttribute("data-id") === selected);
          });
        }
        function bind(el, file){
          el.setAttribute("data-id", file.id);
          el.onclick = function(e){
            if (e.target.closest("a")) return;
            openFile(file);
          };
        }
        function draw(){
          applyScale();
          document.querySelectorAll("#views button").forEach(function(b){
            b.classList.toggle("on", b.getAttribute("data-view") === view);
          });
          shown = visible();
          const count = document.querySelector(".sub");
          count.textContent = "From \(Self.escape(deviceName)) — " + shown.length + " item" + (shown.length === 1 ? "" : "s") + ". Click to play, or download.";
          main.replaceChildren();
          if (!FILES.length) {
            const p = document.createElement("p");
            p.className = "empty";
            p.textContent = "This Mac is online with UnZip. Ask them to tap Share on the files they want to send.";
            main.appendChild(p);
            return;
          }
          if (!shown.length) {
            const p = document.createElement("p");
            p.className = "empty";
            p.textContent = "No files match this view.";
            main.appendChild(p);
            return;
          }
          if (view === "details") {
            const table = document.createElement("table");
            table.innerHTML = "<thead><tr><th>Name</th><th>Kind</th><th>Size</th><th></th></tr></thead>";
            const tb = document.createElement("tbody");
            shown.forEach(function(file){
              const tr = document.createElement("tr");
              const name = document.createElement("td");
              name.className = "name";
              name.appendChild(glyph(file));
              const label = document.createElement("span");
              label.textContent = file.name;
              name.appendChild(label);
              const kind = document.createElement("td");
              kind.className = "muted";
              kind.textContent = kindLabel(file.kind);
              const sz = document.createElement("td");
              sz.className = "muted";
              sz.textContent = bytes(file.size);
              const act = document.createElement("td");
              const a = document.createElement("a");
              a.className = "dl";
              a.href = "/d/" + file.id;
              a.textContent = "Download";
              act.appendChild(a);
              tr.append(name, kind, sz, act);
              bind(tr, file);
              tb.appendChild(tr);
            });
            table.appendChild(tb);
            main.appendChild(table);
          } else if (view === "list") {
            const wrap = document.createElement("div");
            wrap.className = "rows";
            shown.forEach(function(file){
              const row = document.createElement("div");
              row.className = "row";
              row.appendChild(glyph(file));
              const label = document.createElement("span");
              label.textContent = file.name;
              const sz = document.createElement("span");
              sz.className = "size";
              sz.textContent = bytes(file.size);
              const a = document.createElement("a");
              a.className = "dl";
              a.href = "/d/" + file.id;
              a.textContent = "Download";
              row.append(label, sz, a);
              bind(row, file);
              wrap.appendChild(row);
            });
            main.appendChild(wrap);
          } else {
            const wrap = document.createElement("div");
            wrap.className = "tiles";
            shown.forEach(function(file){
              const tile = document.createElement("div");
              tile.className = "tile";
              tile.appendChild(glyph(file));
              const label = document.createElement("div");
              label.className = "tile-name";
              label.textContent = file.name;
              tile.appendChild(label);
              bind(tile, file);
              wrap.appendChild(tile);
            });
            main.appendChild(wrap);
          }
          highlight();
        }
        draw();
        </script>
        </body></html>
        """
    }

    static func mimeType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg", "jpe", "jfif": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp", "dib": return "image/bmp"
        case "svg": return "image/svg+xml"
        case "heic", "heif": return "image/heic"
        case "mp4", "m4v", "m4p": return "video/mp4"
        case "mov", "qt": return "video/quicktime"
        case "webm": return "video/webm"
        case "ogv": return "video/ogg"
        case "mp3", "mp2", "mpga": return "audio/mpeg"
        case "m4a", "aac", "m4b": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "flac": return "audio/flac"
        case "opus": return "audio/opus"
        default: return "application/octet-stream"
        }
    }

    static func byteRange(from header: String, size: Int) -> (Int, Int)? {
        guard size > 0 else { return nil }
        guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) else {
            return nil
        }
        let value = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let start = Int(parts.first ?? "") ?? 0
        let end = parts.count > 1 && !parts[1].isEmpty ? min(Int(parts[1]) ?? (size - 1), size - 1) : size - 1
        guard start >= 0, start <= end, start < size else { return nil }
        return (start, end)
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
