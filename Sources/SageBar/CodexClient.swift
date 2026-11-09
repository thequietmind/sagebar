import Darwin
import Foundation
import SageBarCore

enum CodexClient {
    static func executable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    static func fetch() throws -> UsageSnapshot {
        guard let executable = executable() else { throw UsageError.codexMissing }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UsageError.codexUnavailable }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            for _ in 0..<10 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        try send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"sagebar","title":"SageBar","version":"\#(AppInfo.version)"}}}"#, to: input)
        var buffer = Data()
        var initialized = false
        var accountLabel: String?
        let deadline = Date().addingTimeInterval(25)
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while Date() < deadline {
            let result = poll(&descriptor, 1, 250)
            if result < 0 {
                if errno == EINTR { continue }
                throw UsageError.codexUnavailable
            }
            guard result > 0 else {
                if !process.isRunning { throw UsageError.codexUnavailable }
                continue
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageError.codexUnavailable }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 2_000_000 else { throw UsageError.invalidResponse }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { continue }
                guard let id = envelope.id else { continue }
                if envelope.error != nil && id != 3 { throw UsageError.codexUnavailable }
                if id == 1 && !initialized {
                    initialized = true
                    try send(#"{"method":"initialized"}"#, to: input)
                    try send(#"{"id":3,"method":"account/read","params":{"refreshToken":false}}"#, to: input)
                } else if id == 3 {
                    if let account = try? JSONDecoder().decode(AccountReply.self, from: line).result.account {
                        accountLabel = [account.email, account.workspaceName].compactMap { $0 }.joined(separator: " · ")
                    }
                    try send(#"{"id":2,"method":"account/rateLimits/read"}"#, to: input)
                } else if id == 2 {
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let result = object["result"] as? [String: Any] else { throw UsageError.invalidResponse }
                    let snapshot = try UsageParser.codex(JSONSerialization.data(withJSONObject: result))
                    return UsageSnapshot(limits: snapshot.limits, fetchedAt: snapshot.fetchedAt, note: snapshot.note,
                                         isBlocked: snapshot.isBlocked, accountLabel: accountLabel)
                }
            }
        }
        throw UsageError.codexTimedOut
    }

    private static func send(_ message: String, to pipe: Pipe) throws {
        try pipe.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
    }

    private struct Envelope: Decodable {
        struct Failure: Decodable { let code: Int }
        let id: Int?
        let error: Failure?
    }

    private struct AccountReply: Decodable {
        struct Result: Decodable {
            struct Account: Decodable { let email: String?; let workspaceName: String? }
            let account: Account?
        }
        let result: Result
    }
}
