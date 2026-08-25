import Foundation

final class AppServerClient {
    private let lock = NSLock()
    private let readQueue = DispatchQueue(label: "token-monitor.app-server.read")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()
    private var nextID = 1
    private var callbacks: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private let logURL: URL

    private(set) var connectionMode: String?
    var onNotification: ((String, [String: Any]) -> Void)?

    init(logURL: URL) {
        self.logURL = logURL
    }

    deinit { close() }

    func connect() throws -> String {
        guard let codex = Self.findCodexBinary() else { throw MonitorError.codexNotFound }
        var failures: [String] = []
        var candidates: [(String, [String])] = []
        let controlSocket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/app-server-control/app-server-control.sock")
        if FileManager.default.fileExists(atPath: controlSocket.path) {
            candidates.append(("桌面连接", ["app-server", "proxy"]))
        }
        candidates.append(("独立连接", ["app-server", "--stdio"]))
        for candidate in candidates {
            do {
                try spawn(executable: codex, arguments: candidate.1)
                _ = try request(
                    method: "initialize",
                    params: ["clientInfo": [
                        "name": "token_usage_monitor_macos",
                        "title": "Token监测",
                        "version": "1.2.0"
                    ]],
                    timeout: 12
                )
                try notify(method: "initialized", params: [:])
                connectionMode = candidate.0
                return candidate.0
            } catch {
                failures.append("\(candidate.0): \(error.localizedDescription)")
                close()
            }
        }
        throw MonitorError.server(failures.joined(separator: "；"))
    }

    func request(method: String, params: [String: Any]? = nil, timeout: TimeInterval = 15) throws -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        var received: Result<[String: Any], Error>?
        let requestID: Int = lock.withLock {
            let value = nextID
            nextID += 1
            callbacks[value] = { result in
                received = result
                semaphore.signal()
            }
            return value
        }

        var payload: [String: Any] = ["id": requestID, "method": method]
        if let params { payload["params"] = params }
        do {
            try send(payload)
        } catch {
            _ = lock.withLock { callbacks.removeValue(forKey: requestID) }
            throw error
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            _ = lock.withLock { callbacks.removeValue(forKey: requestID) }
            throw MonitorError.timeout(method)
        }
        switch received {
        case .success(let response): return response
        case .failure(let error): throw error
        case .none: throw MonitorError.invalidResponse
        }
    }

    func notify(method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    func close() {
        let pending: [(Result<[String: Any], Error>) -> Void] = lock.withLock {
            let values = Array(callbacks.values)
            callbacks.removeAll()
            return values
        }
        pending.forEach { $0(.failure(MonitorError.processEnded)) }
        output?.readabilityHandler = nil
        input?.closeFile()
        output?.closeFile()
        input = nil
        output = nil
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        connectionMode = nil
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func spawn(executable: String, arguments: [String]) throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            _ = try? log.seekToEnd()
            process.standardError = log
        }

        let output = stdoutPipe.fileHandleForReading
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.readQueue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.failPending(MonitorError.processEnded)
        }
        try process.run()
        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        self.output = output
    }

    private func send(_ object: [String: Any]) throws {
        guard let process, process.isRunning, let input else { throw MonitorError.processEnded }
        let data = try JSONSerialization.data(withJSONObject: object)
        lock.lock()
        defer { lock.unlock() }
        try input.write(contentsOf: data)
        try input.write(contentsOf: Data([0x0A]))
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message.integer("id") {
            if message["method"] != nil, message["result"] == nil, message["error"] == nil {
                let error: [String: Any] = ["code": -32601, "message": "Client method not supported"]
                try? send(["id": id, "error": error])
                return
            }
            let callback = lock.withLock { callbacks.removeValue(forKey: id) }
            if let error = message.dictionary("error") {
                callback?(.failure(MonitorError.server(error.string("message") ?? "Codex 请求失败")))
            } else {
                callback?(.success(message.dictionary("result") ?? [:]))
            }
            return
        }
        if let method = message.string("method") {
            onNotification?(method, message.dictionary("params") ?? [:])
        }
    }

    private func failPending(_ error: Error) {
        let pending: [(Result<[String: Any], Error>) -> Void] = lock.withLock {
            let values = Array(callbacks.values)
            callbacks.removeAll()
            return values
        }
        pending.forEach { $0(.failure(error)) }
    }

    private static func findCodexBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CODEX_BINARY"], FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            candidates.append(contentsOf: versions.sorted().reversed().map { "\(nvmRoot)/\($0)/bin/codex" })
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
