import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var stdoutText: String {
        String(data: stdout, encoding: .utf8)
            ?? String(data: stdout, encoding: .isoLatin1)
            ?? ""
    }

    var stderrText: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    var succeeded: Bool { status == 0 }
}

enum ProcessRunner {
    static func which(_ name: String) -> String? {
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin"
        ]
        for folder in extras {
            let path = "\(folder)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func run(
        _ launchPath: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        var env = ProcessInfo.processInfo.environment
        if let environment {
            env.merge(environment) { _, new in new }
        }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    @discardableResult
    static func runChecked(
        _ launchPath: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        stdin: Data? = nil
    ) throws -> ProcessResult {
        let result = try run(launchPath, arguments: arguments, currentDirectory: currentDirectory, stdin: stdin)
        if !result.succeeded {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UnZipError.failed(detail.isEmpty ? "Command failed: \(launchPath)" : detail)
        }
        return result
    }
}

enum Toolchain {
    static var unzip: String { "/usr/bin/unzip" }
    static var zip: String { "/usr/bin/zip" }
    static var ditto: String { "/usr/bin/ditto" }
    static var tar: String { "/usr/bin/tar" }
    static var hdiutil: String { "/usr/bin/hdiutil" }
    static var gzip: String { "/usr/bin/gzip" }
    static var bunzip2: String { "/usr/bin/bunzip2" }
    static var sftp: String { "/usr/bin/sftp" }
    static var ssh: String { "/usr/bin/ssh" }

    static var unar: String? { ProcessRunner.which("unar") }
    static var lsar: String? { ProcessRunner.which("lsar") }
    static var sevenZip: String? { ProcessRunner.which("7z") ?? ProcessRunner.which("7zz") }
    static var unrar: String? { ProcessRunner.which("unrar") }
    static var xz: String? { ProcessRunner.which("xz") }

    static var rarReady: Bool { unar != nil || sevenZip != nil || unrar != nil }
    static var sevenReady: Bool { sevenZip != nil || unar != nil }
}
