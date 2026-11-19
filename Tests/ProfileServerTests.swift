import XCTest
import Network
@testable import Customize

/// Talks to the loopback server with raw NWConnection sockets instead of
/// URLSession, so App Transport Security can't interfere with plain HTTP to 127.0.0.1.
final class ProfileServerTests: XCTestCase {

    // MARK: - Helpers

    private func makeProfile() -> Data {
        var data = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict/></plist>\n".utf8)
        // Make the body large enough to arrive in several reads.
        data.append(contentsOf: (0..<60_000).map { UInt8(truncatingIfNeeded: $0) })
        return data
    }

    private func exchange(port: Int, _ chunks: [String], delayBetweenChunks: TimeInterval = 0) async throws -> TestHTTPResponse {
        let client = RawHTTPExchange(
            port: UInt16(port),
            chunks: chunks.map { Data($0.utf8) },
            delayBetweenChunks: delayBetweenChunks
        )
        let raw = try await client.run(timeout: 5)
        return try TestHTTPResponse(raw)
    }

    private func get(_ path: String, port: Int) -> String {
        "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUser-Agent: CustomizeTests\r\nConnection: close\r\n\r\n"
    }

    private func assertEventuallyRefused(port: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<40 {
            let connected = await ConnectProbe(port: UInt16(port)).run(timeout: 2)
            if !connected { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("The server still accepts connections after it should have stopped", file: file, line: line)
    }

    // MARK: - Tests

    func testServesProfileWithHeadersOverLoopback() async throws {
        let profile = makeProfile()
        let server = ProfileServer(profile: profile)
        let url = try await server.start()
        defer { server.stop() }

        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, server.path)
        XCTAssertTrue(url.path.hasSuffix("/Customize-Icons.mobileconfig"))
        let port = try XCTUnwrap(url.port)
        XCTAssertGreaterThan(port, 0)

        let response = try await exchange(port: port, [get(url.path, port: port)])
        XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(response.headers["content-type"], "application/x-apple-aspen-config")
        XCTAssertEqual(response.headers["content-length"], String(profile.count))
        XCTAssertEqual(response.headers["connection"], "close")
        XCTAssertEqual(response.headers["cache-control"], "no-store")
        XCTAssertEqual(response.headers["content-disposition"], "attachment; filename=\"Customize-Icons.mobileconfig\"")
        XCTAssertEqual(response.body.count, profile.count)
        XCTAssertEqual(response.body, profile)
    }

    func testUnknownPathsReturn404() async throws {
        let server = ProfileServer(profile: makeProfile())
        let url = try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(url.port)

        for path in ["/favicon.ico", "/", "/Customize-Icons.mobileconfig", url.path + "x"] {
            let response = try await exchange(port: port, [get(path, port: port)])
            XCTAssertEqual(response.statusLine, "HTTP/1.1 404 Not Found", path)
            XCTAssertEqual(response.headers["content-length"], "0", path)
            XCTAssertEqual(response.headers["connection"], "close", path)
            XCTAssertNil(response.headers["content-type"], path)
            XCTAssertTrue(response.body.isEmpty, path)
        }
    }

    func testHeadReturnsHeadersWithoutBody() async throws {
        let profile = makeProfile()
        let server = ProfileServer(profile: profile)
        let url = try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(url.port)

        let request = "HEAD \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        let response = try await exchange(port: port, [request])
        XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(response.headers["content-type"], "application/x-apple-aspen-config")
        XCTAssertEqual(response.headers["content-length"], String(profile.count))
        XCTAssertTrue(response.body.isEmpty)
    }

    func testWaitsForTheEndOfTheRequestHeaders() async throws {
        let profile = makeProfile()
        let server = ProfileServer(profile: profile)
        let url = try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(url.port)

        let request = get(url.path, port: port)
        let splitIndex = request.index(request.startIndex, offsetBy: 20)
        let chunks = [String(request[..<splitIndex]), String(request[splitIndex...])]
        let response = try await exchange(port: port, chunks, delayBetweenChunks: 0.3)
        XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(response.body, profile)
    }

    func testIgnoresQueryString() async throws {
        let profile = makeProfile()
        let server = ProfileServer(profile: profile)
        let url = try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(url.port)

        let response = try await exchange(port: port, [get(url.path + "?download=1", port: port)])
        XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(response.body, profile)
    }

    func testNotifiesWhenTheProfileWasServed() async throws {
        let served = expectation(description: "profile served")
        let server = ProfileServer(profile: makeProfile(), onProfileServed: {
            served.fulfill()
        })
        let url = try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(url.port)

        let response = try await exchange(port: port, [get(url.path, port: port)])
        XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
        await fulfillment(of: [served], timeout: 5)
    }

    func testEachServerUsesItsOwnSecretPath() {
        let first = ProfileServer(profile: Data([1]))
        let second = ProfileServer(profile: Data([1]))
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(first.path.hasPrefix("/"))
        XCTAssertTrue(first.path.hasSuffix("/" + WebClipProfile.fileName))
    }

    func testRequestLineParsing() {
        let plain = ProfileServer.parseRequestLine(Data("GET /a/b.mobileconfig?x=1 HTTP/1.1\r\nHost: x".utf8))
        XCTAssertEqual(plain.method, "GET")
        XCTAssertEqual(plain.target, "/a/b.mobileconfig")

        let absolute = ProfileServer.parseRequestLine(Data("HEAD http://127.0.0.1:8080/a/b.mobileconfig HTTP/1.1".utf8))
        XCTAssertEqual(absolute.method, "HEAD")
        XCTAssertEqual(absolute.target, "/a/b.mobileconfig")

        let garbage = ProfileServer.parseRequestLine(Data())
        XCTAssertEqual(garbage.method, "")
        XCTAssertEqual(garbage.target, "")
    }

    func testStopClosesTheListener() async throws {
        let server = ProfileServer(profile: makeProfile())
        let url = try await server.start()
        let port = try XCTUnwrap(url.port)

        let connectedWhileRunning = await ConnectProbe(port: UInt16(port)).run(timeout: 2)
        XCTAssertTrue(connectedWhileRunning)

        server.stop()
        try await assertEventuallyRefused(port: port)
    }

    func testStopsByItselfAfterTheTimeout() async throws {
        let server = ProfileServer(profile: makeProfile(), timeout: 0.5)
        let url = try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(url.port)

        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await assertEventuallyRefused(port: port)
    }

    func testCannotStartAfterStop() async {
        let server = ProfileServer(profile: makeProfile())
        server.stop()
        do {
            _ = try await server.start()
            XCTFail("start() should fail after stop()")
        } catch {
            XCTAssertNotNil(error as? ProfileServerError)
        }
    }
}

// MARK: - Raw HTTP client

private enum TestClientError: Error {
    case timedOut
    case malformedResponse
}

private struct TestHTTPResponse {
    let statusLine: String
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data

    init(_ raw: Data) throws {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw TestClientError.malformedResponse
        }
        let head = String(decoding: raw.subdata(in: raw.startIndex..<split.lowerBound), as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let firstLine = lines.isEmpty ? "" : lines.removeFirst()
        var parsed: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsed[name] = value
        }
        statusLine = firstLine
        headers = parsed
        body = raw.subdata(in: split.upperBound..<raw.endIndex)
    }
}

/// Sends the request (optionally in several chunks) and reads until the server closes.
/// All state is touched only on `queue`.
private final class RawHTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let chunks: [Data]
    private let delayBetweenChunks: TimeInterval
    private let queue = DispatchQueue(label: "CustomizeTests.RawHTTPExchange")
    private var received = Data()
    private var continuation: CheckedContinuation<Data, Error>?

    init(port: UInt16, chunks: [Data], delayBetweenChunks: TimeInterval) {
        self.connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
        self.chunks = chunks
        self.delayBetweenChunks = delayBetweenChunks
    }

    func run(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { state in
                    self.handle(state)
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(TestClientError.timedOut))
                }
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            receiveMore()
            send(chunkAt: 0)
        case .waiting(let error), .failed(let error):
            finish(.failure(error))
        default:
            break
        }
    }

    private func send(chunkAt index: Int) {
        guard index < chunks.count else { return }
        connection.send(content: chunks[index], completion: .contentProcessed { error in
            if let error {
                self.finish(.failure(error))
                return
            }
            guard index + 1 < self.chunks.count else { return }
            self.queue.asyncAfter(deadline: .now() + self.delayBetweenChunks) {
                self.send(chunkAt: index + 1)
            }
        })
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data {
                self.received.append(data)
            }
            if isComplete {
                self.finish(.success(self.received))
            } else if let error {
                if self.received.isEmpty {
                    self.finish(.failure(error))
                } else {
                    self.finish(.success(self.received))
                }
            } else {
                self.receiveMore()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(with: result)
    }
}

/// Reports whether a TCP connection to 127.0.0.1:port can be established.
private final class ConnectProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "CustomizeTests.ConnectProbe")
    private var continuation: CheckedContinuation<Bool, Never>?

    init(port: UInt16) {
        self.connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
    }

    func run(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.finish(true)
                    case .waiting, .failed:
                        self.finish(false)
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(false)
                }
            }
        }
    }

    private func finish(_ connected: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: connected)
    }
}
