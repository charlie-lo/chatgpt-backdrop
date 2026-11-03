import Foundation

/// A page advertised by a locally running Chromium renderer.
struct DebugTarget: Decodable, Identifiable {
    let id: String
    let type: String
    let title: String
    let url: String
    let webSocketDebuggerUrl: String?
}

enum CDPError: LocalizedError {
    case invalidPort
    case invalidEndpoint
    case httpStatus(Int)
    case malformedResponse
    case responseTooLarge
    case disconnected
    case timedOut
    case protocolFailure(code: Int, message: String)
    case runtimeException(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "The debug port must be between 1024 and 65535."
        case .invalidEndpoint: return "Connection refused. Only a local page debug endpoint on the specified port is allowed."
        case .httpStatus(let code): return "The local debug service returned HTTP \(code)."
        case .malformedResponse: return "The local debug service returned an invalid response."
        case .responseTooLarge: return "The local debug response exceeds the size limit."
        case .disconnected: return "The local connection to ChatGPT was lost."
        case .timedOut: return "The local ChatGPT connection timed out. Connect again."
        case .protocolFailure(let code, let message): return "Debug command failed (\(code)): \(message)"
        case .runtimeException(let message): return "Background styling failed: \(message)"
        }
    }
}

/// Discovery must never follow an HTTP redirect away from loopback.
private final class LoopbackSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Owns one receive loop and multiplexes CDP replies by request id.
/// All continuation bookkeeping runs on the main actor; no chat data is logged.
@MainActor
final class CDPClient {
    private struct PendingCommand {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
    }

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [Int: PendingCommand] = [:]
    private var nextID = 1
    private var generation = UUID()
    private var handshake: CheckedContinuation<Void, Error>?
    private var handshakeTimeout: Task<Void, Never>?

    private(set) var isConnected = false

    deinit {
        receiveTask?.cancel()
        handshakeTimeout?.cancel()
        handshake?.resume(throwing: CDPError.disconnected)
        for item in pending.values {
            item.timeout.cancel()
            item.continuation.resume(throwing: CDPError.disconnected)
        }
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    static func discover(port: Int) async throws -> [DebugTarget] {
        try validate(port: port)
        let configuration = sessionConfiguration()
        let delegate = LoopbackSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CDPError.malformedResponse }
        guard response.statusCode == 200 else { throw CDPError.httpStatus(response.statusCode) }
        guard data.count <= 2 * 1024 * 1024 else { throw CDPError.responseTooLarge }
        do {
            return try JSONDecoder().decode([DebugTarget].self, from: data)
        } catch {
            throw CDPError.malformedResponse
        }
    }

    func discover(port: Int) async throws -> [DebugTarget] {
        try await Self.discover(port: port)
    }

    static func validatedWebSocketURL(target: DebugTarget, port: Int) throws -> URL {
        try validate(port: port)
        guard target.type == "page",
              let endpoint = target.webSocketDebuggerUrl,
              let components = URLComponents(string: endpoint),
              components.scheme?.lowercased() == "ws",
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              components.port == port,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.path.hasPrefix("/devtools/"),
              let url = components.url else { throw CDPError.invalidEndpoint }
        return url
    }

    func connect(target: DebugTarget, port: Int) async throws {
        let url = try Self.validatedWebSocketURL(target: target, port: port)
        disconnect()
        let connectionGeneration = UUID()
        generation = connectionGeneration
        let delegate = LoopbackSessionDelegate()
        let configuration = Self.sessionConfiguration()
        // Discovery and handshakes are short; an established theme session can remain open.
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let newSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session = newSession
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let newSocket = newSession.webSocketTask(with: request)
        socket = newSocket
        newSocket.maximumMessageSize = 2 * 1024 * 1024
        newSocket.resume()

        receiveTask = Task { @MainActor [weak self, weak newSocket] in
            guard let newSocket = newSocket else { return }
            while !Task.isCancelled {
                do {
                    let message = try await newSocket.receive()
                    guard let self = self, self.generation == connectionGeneration else { return }
                    self.handle(message: message)
                } catch {
                    guard let self = self, self.generation == connectionGeneration else { return }
                    self.endConnection(error: error)
                    return
                }
            }
        }

        do {
            try await ping(newSocket, generation: connectionGeneration)
            guard generation == connectionGeneration, socket != nil else { throw CDPError.disconnected }
            isConnected = true
        } catch {
            if generation == connectionGeneration { endConnection(error: error) }
            throw error
        }
    }

    func command(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard isConnected, let socket = socket else { throw CDPError.disconnected }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { throw CDPError.malformedResponse }
        let connectionGeneration = generation

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    guard let self = self, self.generation == connectionGeneration else { return }
                    self.finish(id: id, result: .failure(CDPError.timedOut))
                }
                pending[id] = PendingCommand(continuation: continuation, timeout: timeout)
                Task { @MainActor [weak self] in
                    do { try await socket.send(.string(text)) }
                    catch {
                        guard let self = self, self.generation == connectionGeneration else { return }
                        self.finish(id: id, result: .failure(error))
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self = self, self.generation == connectionGeneration else { return }
                self.finish(id: id, result: .failure(CancellationError()))
            }
        })
    }

    func disconnect() {
        endConnection(error: CDPError.disconnected)
    }

    private static func validate(port: Int) throws {
        guard (1024...65535).contains(port) else { throw CDPError.invalidPort }
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        // This connection must not be routed through the user's proxy settings.
        config.connectionProxyDictionary = [:]
        return config
    }

    private func ping(_ task: URLSessionWebSocketTask, generation connectionGeneration: UUID) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                handshake = continuation
                handshakeTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    guard let self = self, self.generation == connectionGeneration else { return }
                    self.finishHandshake(error: CDPError.timedOut)
                }
                task.sendPing { [weak self] error in
                    Task { @MainActor in
                        guard let self = self, self.generation == connectionGeneration else { return }
                        self.finishHandshake(error: error)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self = self, self.generation == connectionGeneration else { return }
                self.finishHandshake(error: CancellationError())
            }
        })
    }

    private func finishHandshake(error: Error?) {
        guard let continuation = handshake else { return }
        handshake = nil
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        if let error = error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: ()) }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let received): data = received
        case .string(let text): data = Data(text.utf8)
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else { return } // Unsolicited CDP events are intentionally ignored.

        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = String((error["message"] as? String ?? "Unknown error").prefix(240))
            finish(id: id, result: .failure(CDPError.protocolFailure(code: code, message: message)))
            return
        }
        guard let result = object["result"] as? [String: Any] else {
            finish(id: id, result: .failure(CDPError.malformedResponse))
            return
        }
        if let exception = result["exceptionDetails"] as? [String: Any] {
            let message = String((exception["text"] as? String ?? "JavaScript exception").prefix(240))
            finish(id: id, result: .failure(CDPError.runtimeException(message)))
            return
        }
        finish(id: id, result: .success(result))
    }

    private func finish(id: Int, result: Result<[String: Any], Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel()
        item.continuation.resume(with: result)
    }

    private func endConnection(error: Error) {
        generation = UUID()
        isConnected = false
        finishHandshake(error: error)
        let oldPending = pending
        pending.removeAll()
        for item in oldPending.values {
            item.timeout.cancel()
            item.continuation.resume(throwing: error)
        }
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
