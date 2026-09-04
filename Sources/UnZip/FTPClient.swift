import Foundation
import Network

struct FTPListItem: Sendable {
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?
    var permissions: String?
}

final class FTPClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.unzip.ftp")
    private var connection: NWConnection?
    private var host = ""
    private var port: UInt16 = 21
    private var username = ""
    private var password = ""
    private var useTLS = false
    private var leftover = Data()

    var currentPath: String = "/"

    func connect(host: String, port: UInt16, username: String, password: String, useTLS: Bool) throws {
        disconnect()
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useTLS = useTLS

        let params: NWParameters = useTLS ? .tls : .tcp
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 21, using: params)
        connection = conn
        try start(conn)
        _ = try readReply()
        try send("USER \(username.isEmpty ? "anonymous" : username)")
        var reply = try readReply()
        if reply.code == 331 {
            try send("PASS \(password.isEmpty ? "anonymous@unzip.local" : password)")
            reply = try readReply()
        }
        guard (200..<300).contains(reply.code) else {
            throw UnZipError.failed(reply.message)
        }
        try send("TYPE I")
        _ = try readReply()
        currentPath = try pwd()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        leftover = Data()
        currentPath = "/"
    }

    func pwd() throws -> String {
        try send("PWD")
        let reply = try readReply()
        if let start = reply.message.firstIndex(of: "\""), let end = reply.message.lastIndex(of: "\""), start < end {
            return String(reply.message[reply.message.index(after: start)..<end])
        }
        return currentPath
    }

    func cwd(_ path: String) throws {
        try send("CWD \(path)")
        let reply = try readReply()
        guard (200..<300).contains(reply.code) else { throw UnZipError.failed(reply.message) }
        currentPath = try pwd()
    }

    func list() throws -> [FTPListItem] {
        let data = try withDataConnection {
            try send("LIST")
            let reply = try readReply()
            guard (100..<200).contains(reply.code) || (200..<300).contains(reply.code) else {
                throw UnZipError.failed(reply.message)
            }
        }
        if (200..<400).contains((try? readReply().code) ?? 0) {
            // consume completion
        }
        return parseList(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "")
    }

    func download(path: String, to destination: URL, progress: ((Int64) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try withDataConnection {
            try send("RETR \(path)")
            let reply = try readReply()
            guard (100..<200).contains(reply.code) else { throw UnZipError.failed(reply.message) }
        }
        try data.write(to: destination)
        progress?(Int64(data.count))
        _ = try? readReply()
    }

    func upload(local: URL, remoteName: String, progress: ((Int64) -> Void)? = nil) throws {
        let data = try Data(contentsOf: local)
        try withDataConnectionWrite(data) {
            try send("STOR \(remoteName)")
            let reply = try readReply()
            guard (100..<200).contains(reply.code) else { throw UnZipError.failed(reply.message) }
        }
        progress?(Int64(data.count))
        _ = try? readReply()
    }

    func mkdir(_ name: String) throws {
        try send("MKD \(name)")
        let reply = try readReply()
        guard (200..<400).contains(reply.code) else { throw UnZipError.failed(reply.message) }
    }

    func delete(_ name: String, directory: Bool) throws {
        try send(directory ? "RMD \(name)" : "DELE \(name)")
        let reply = try readReply()
        guard (200..<300).contains(reply.code) else { throw UnZipError.failed(reply.message) }
    }

    // MARK: - Protocol

    private struct Reply {
        var code: Int
        var message: String
    }

    private func send(_ line: String) throws {
        guard let connection else { throw UnZipError.notConnected }
        let payload = Data((line + "\r\n").utf8)
        try awaitResult { (box: ResultBox<Void>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    box.complete(.failure(UnZipError.failed(error.localizedDescription)))
                } else {
                    box.complete(.success(()))
                }
            })
        }
    }

    private func readReply() throws -> Reply {
        var lines: [String] = []
        while true {
            let line = try readLine()
            lines.append(line)
            if line.count >= 3,
               line.prefix(3).allSatisfy(\.isNumber),
               line.count == 3 || (line.count > 3 && line[line.index(line.startIndex, offsetBy: 3)] == " ") {
                let code = Int(line.prefix(3)) ?? 0
                return Reply(code: code, message: lines.joined(separator: "\n"))
            }
        }
    }

    private func readLine() throws -> String {
        while true {
            if let range = leftover.range(of: Data([13, 10])) {
                let line = leftover.subdata(in: leftover.startIndex..<range.lowerBound)
                leftover.removeSubrange(leftover.startIndex..<range.upperBound)
                return String(data: line, encoding: .utf8) ?? String(data: line, encoding: .isoLatin1) ?? ""
            }
            leftover.append(try receiveOnce())
        }
    }

    private func receiveOnce() throws -> Data {
        guard let connection else { throw UnZipError.notConnected }
        return try awaitResult { box in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    box.complete(.failure(UnZipError.failed(error.localizedDescription)))
                } else if let data, !data.isEmpty {
                    box.complete(.success(data))
                } else if isComplete {
                    box.complete(.failure(UnZipError.failed("FTP connection closed.")))
                } else {
                    box.complete(.success(Data()))
                }
            }
        }
    }

    private func start(_ connection: NWConnection) throws {
        try awaitResult { (box: ResultBox<Void>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    box.complete(.success(()))
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    box.complete(.failure(UnZipError.failed(error.localizedDescription)))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    box.complete(.failure(UnZipError.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func pasv() throws -> (host: String, port: UInt16) {
        try send("PASV")
        let reply = try readReply()
        guard (200..<300).contains(reply.code) else { throw UnZipError.failed(reply.message) }
        let digits = reply.message.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count >= 6 else { throw UnZipError.failed("Could not parse PASV response.") }
        let h = digits.suffix(6)
        let arr = Array(h)
        return ("\(arr[0]).\(arr[1]).\(arr[2]).\(arr[3])", UInt16(arr[4] * 256 + arr[5]))
    }

    private func openDataConnection() throws -> NWConnection {
        let target = try pasv()
        let params: NWParameters = useTLS ? .tls : .tcp
        let dataConn = NWConnection(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port) ?? 20, using: params)
        try start(dataConn)
        return dataConn
    }

    private func withDataConnection(_ command: () throws -> Void) throws -> Data {
        let dataConn = try openDataConnection()
        defer { dataConn.cancel() }
        try command()
        var buffer = Data()
        while true {
            let chunk: Data = try awaitResult { box in
                dataConn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, error in
                    if let error {
                        box.complete(.failure(UnZipError.failed(error.localizedDescription)))
                    } else if let data {
                        box.complete(.success(data))
                    } else if done {
                        box.complete(.success(Data()))
                    } else {
                        box.complete(.success(Data()))
                    }
                }
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return buffer
    }

    private func withDataConnectionWrite(_ payload: Data, _ command: () throws -> Void) throws {
        let dataConn = try openDataConnection()
        defer { dataConn.cancel() }
        try command()
        try awaitResult { (box: ResultBox<Void>) in
            dataConn.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    box.complete(.failure(UnZipError.failed(error.localizedDescription)))
                } else {
                    box.complete(.success(()))
                }
            })
        }
    }

    private func parseList(_ text: String) -> [FTPListItem] {
        var items: [FTPListItem] = []
        for raw in text.split(whereSeparator: \.isNewline).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let unix = parseUnixList(line) {
                items.append(unix)
            } else if let dos = parseDOSList(line) {
                items.append(dos)
            }
        }
        return items.filter { $0.name != "." && $0.name != ".." }
    }

    private func parseUnixList(_ line: String) -> FTPListItem? {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 9, let first = parts.first, "dl-".contains(first.first ?? " ") else { return nil }
        let isDir = first.hasPrefix("d") || first.hasPrefix("l")
        let size = Int64(parts[4]) ?? 0
        let name = parts.dropFirst(8).joined(separator: " ")
        return FTPListItem(name: name, isDirectory: isDir && !first.hasPrefix("l") ? true : first.hasPrefix("d"), size: size, modified: nil, permissions: first)
    }

    private func parseDOSList(_ line: String) -> FTPListItem? {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 4 else { return nil }
        let isDir = parts[2].caseInsensitiveCompare("<DIR>") == .orderedSame
        let size = isDir ? 0 : Int64(parts[2].replacingOccurrences(of: ",", with: "")) ?? 0
        let name = parts.dropFirst(3).joined(separator: " ")
        return FTPListItem(name: name, isDirectory: isDir, size: size, modified: nil, permissions: nil)
    }

    private func awaitResult<T: Sendable>(_ body: (ResultBox<T>) -> Void) throws -> T {
        let box = ResultBox<T>()
        body(box)
        if !Thread.isMainThread {
            box.semaphore.wait()
        } else {
            while true {
                box.lock.lock()
                let ready = box.value != nil
                box.lock.unlock()
                if ready { break }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        box.lock.lock()
        let stored = box.value
        box.lock.unlock()
        switch stored! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var value: Result<T, Error>?
    let semaphore = DispatchSemaphore(value: 0)

    func complete(_ result: Result<T, Error>) {
        lock.lock()
        value = result
        lock.unlock()
        semaphore.signal()
    }
}

enum SFTPClient {
    static func list(host: String, port: Int, username: String, path: String) throws -> [FTPListItem] {
        let script = "ls -la \(path)\n"
        let result = try ProcessRunner.runChecked(Toolchain.sftp, arguments: [
            "-b", "-", "-oBatchMode=yes", "-oStrictHostKeyChecking=accept-new", "-P", "\(port)", "\(username)@\(host)"
        ], stdin: Data(script.utf8))
        return parse(result.stdoutText)
    }

    static func download(host: String, port: Int, username: String, remote: String, local: URL) throws {
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = "get \"\(remote)\" \"\(local.path)\"\n"
        try ProcessRunner.runChecked(Toolchain.sftp, arguments: [
            "-b", "-", "-oBatchMode=yes", "-oStrictHostKeyChecking=accept-new", "-P", "\(port)", "\(username)@\(host)"
        ], stdin: Data(script.utf8))
    }

    static func upload(host: String, port: Int, username: String, local: URL, remote: String) throws {
        let script = "put \"\(local.path)\" \"\(remote)\"\n"
        try ProcessRunner.runChecked(Toolchain.sftp, arguments: [
            "-b", "-", "-oBatchMode=yes", "-oStrictHostKeyChecking=accept-new", "-P", "\(port)", "\(username)@\(host)"
        ], stdin: Data(script.utf8))
    }

    private static func parse(_ text: String) -> [FTPListItem] {
        var items: [FTPListItem] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 9, let first = parts.first, "dl-".contains(first.first ?? " ") else { continue }
            let name = parts.dropFirst(8).joined(separator: " ")
            if name == "." || name == ".." { continue }
            items.append(
                FTPListItem(
                    name: name,
                    isDirectory: first.hasPrefix("d"),
                    size: Int64(parts[4]) ?? 0,
                    modified: nil,
                    permissions: first
                )
            )
        }
        return items
    }
}
