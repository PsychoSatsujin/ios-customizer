import Foundation
import Network

enum ProfileServerError: LocalizedError {
    case alreadyStarted
    case noPort
    case startTimedOut
    case stopped

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "The installer is already running."
        case .noPort:
            return "The installer could not get a local port."
        case .startTimedOut:
            return "The installer took too long to start."
        case .stopped:
            return "The installer was stopped."
        }
    }
}

/// A tiny HTTP/1.1 server that only listens on 127.0.0.1 and serves one file:
/// the profile, at an unguessable path. Safari downloads it from there and
/// hands it to Settings. Every other path gets 404.
///
/// All mutable state lives on one private serial queue. The server is
/// single-use: once stopped (by `stop()` or the timeout) it can't be restarted.
final class ProfileServer: @unchecked Sendable {
    static let defaultTimeout: TimeInterval = 300

    let profile: Data
    let fileName: String
    /// Request path that returns the profile, e.g. /<UUID>/Customize-Icons.mobileconfig.
    let path: String
    let timeout: TimeInterval

    private let onProfileServed: (@MainActor @Sendable () -> Void)?
    private let queue = DispatchQueue(label: "com.personal.customize.profileserver")

    // Only touched on `queue`.
    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]
    private var answered: Set<Int> = []
    private var nextConnectionID = 0
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var hasStarted = false
    private var isStopped = false

    private static let maxHeaderBytes = 16_384
    private static let maxConnections = 8
    private static let requestTimeout: TimeInterval = 10
    private static let startTimeout: TimeInterval = 5
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// - Parameters:
    ///   - profile: The bytes to serve.
    ///   - fileName: File name Safari should use for the download.
    ///   - timeout: Seconds after start before the server stops by itself.
    ///   - onProfileServed: Called on the main actor each time the profile was sent to a GET request.
    init(
        profile: Data,
        fileName: String = WebClipProfile.fileName,
        timeout: TimeInterval = ProfileServer.defaultTimeout,
        onProfileServed: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let safeName = ProfileServer.sanitizedFileName(fileName)
        self.profile = profile
        self.fileName = safeName
        self.timeout = timeout
        self.onProfileServed = onProfileServed
        self.path = "/" + UUID().uuidString + "/" + safeName
    }

    deinit {
        listener?.cancel()
        for connection in connections.values {
            connection.cancel()
        }
    }

    /// Starts listening on 127.0.0.1 with a system-chosen port and returns the
    /// profile's URL (http://127.0.0.1:PORT/<token>/<file>) once the listener is ready.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async {
                self.startOnQueue(continuation)
            }
        }
    }

    /// Stops listening and closes all connections. Safe to call more than once, from any thread.
    func stop() {
        queue.async {
            self.stopOnQueue()
        }
    }

    // MARK: - Listener

    private func startOnQueue(_ continuation: CheckedContinuation<URL, Error>) {
        if isStopped {
            continuation.resume(throwing: ProfileServerError.stopped)
            return
        }
        if hasStarted {
            continuation.resume(throwing: ProfileServerError.alreadyStarted)
            return
        }
        hasStarted = true
        readyContinuation = continuation

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let newListener = try NWListener(using: parameters)
            listener = newListener
            newListener.stateUpdateHandler = { [weak self] state in
                self?.listenerStateChanged(state)
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.start(queue: queue)
        } catch {
            resumeReady(.failure(error))
            stopOnQueue()
            return
        }

        queue.asyncAfter(deadline: .now() + ProfileServer.startTimeout) { [weak self] in
            guard let self, self.readyContinuation != nil else { return }
            self.resumeReady(.failure(ProfileServerError.startTimedOut))
            self.stopOnQueue()
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue,
                  let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
                resumeReady(.failure(ProfileServerError.noPort))
                stopOnQueue()
                return
            }
            resumeReady(.success(url))
        case .failed(let error):
            resumeReady(.failure(error))
            stopOnQueue()
        case .cancelled:
            resumeReady(.failure(ProfileServerError.stopped))
        default:
            break
        }
    }

    private func resumeReady(_ result: Result<URL, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        continuation.resume(with: result)
    }

    private func stopOnQueue() {
        guard !isStopped else { return }
        isStopped = true
        if let listener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listener = nil
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        answered.removeAll()
        resumeReady(.failure(ProfileServerError.stopped))
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard !isStopped, connections.count < ProfileServer.maxConnections else {
            connection.cancel()
            return
        }
        nextConnectionID += 1
        let id = nextConnectionID
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, buffer: Data())

        // Drop connections that never send a full request (e.g. speculative preconnects).
        // Connections that are already being answered are left alone, because a large
        // profile can take a while to drain if Safari waits for the user to tap Allow.
        queue.asyncAfter(deadline: .now() + ProfileServer.requestTimeout) { [weak self] in
            guard let self, !self.answered.contains(id) else { return }
            self.close(id)
        }
    }

    private func receive(on connection: NWConnection, id: Int, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: ProfileServer.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = buffer
            if let data {
                received.append(data)
            }
            if error != nil || received.count > ProfileServer.maxHeaderBytes {
                self.close(id)
                return
            }
            guard let headerEnd = received.range(of: ProfileServer.headerTerminator) else {
                if isComplete {
                    self.close(id)
                } else {
                    self.receive(on: connection, id: id, buffer: received)
                }
                return
            }
            let head = received.subdata(in: received.startIndex..<headerEnd.lowerBound)
            self.respond(on: connection, id: id, head: head)
        }
    }

    private func respond(on connection: NWConnection, id: Int, head: Data) {
        answered.insert(id)
        let request = ProfileServer.parseRequestLine(head)
        let response = makeResponse(method: request.method, target: request.target)
        connection.send(
            content: response.bytes,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    self.close(id)
                    return
                }
                if response.servedProfile, let callback = self.onProfileServed {
                    Task { @MainActor in
                        callback()
                    }
                }
                // The final message already sent FIN after the data. Give the peer a
                // moment to read it before releasing the connection.
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.close(id)
                }
            }
        )
    }

    private func close(_ id: Int) {
        answered.remove(id)
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: - HTTP

    private struct Response {
        let bytes: Data
        let servedProfile: Bool
    }

    private func makeResponse(method: String, target: String) -> Response {
        let isGet = method == "GET"
        let isHead = method == "HEAD"
        var head: String
        var body = Data()
        var servedProfile = false

        if !(isGet || isHead) {
            head = "HTTP/1.1 405 Method Not Allowed\r\n"
            head += "Allow: GET, HEAD\r\n"
        } else if target == path {
            head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: \(WebClipProfile.contentType)\r\n"
            head += "Content-Disposition: attachment; filename=\"\(fileName)\"\r\n"
            body = profile
            servedProfile = isGet
        } else {
            head = "HTTP/1.1 404 Not Found\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        var bytes = Data(head.utf8)
        if isGet {
            bytes.append(body)
        }
        return Response(bytes: bytes, servedProfile: servedProfile)
    }

    /// Returns the method and the path (without query or fragment) of an HTTP request head.
    static func parseRequestLine(_ head: Data) -> (method: String, target: String) {
        let text = String(decoding: head, as: UTF8.self)
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        let method = parts.first ?? ""
        var target = parts.count > 1 ? parts[1] : ""
        if target.hasPrefix("http://") || target.hasPrefix("https://"), let absolute = URL(string: target) {
            target = absolute.path
        }
        if let cut = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            target = String(target[..<cut])
        }
        return (method: method, target: target)
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "profile.mobileconfig" : cleaned
    }
}
