import Network
import XCTest
@testable import PVWebServer

/// Drives a real server on loopback with raw HTTP, so paths like `//api/x` reach it unnormalized.
final class ROMUploadServerLiveTests: XCTestCase {
    private static let webDAVAgent = "WebDAVFS/3.0.0 (03008000) Darwin/24.0.0"
    private static let browserAgent = "Mozilla/5.0 Safari/605.1.15"

    private var root: URL!
    private var server: ROMUploadServer!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pvweb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("file.txt"))
        server = ROMUploadServer(romsDirectory: root)
        server.bonjourName = "PVWebServerTest-\(UUID().uuidString.prefix(8))"
        server.advertisesWebDAVService = false
        let base = UInt16(45_000 + Int.random(in: 0..<2_000) * 2)
        server.preferredPorts = [base, base + 1, base + 2, base + 3]
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private struct Reply {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    private func raw(_ request: Data) async throws -> Reply {
        let bytes = try await RawClient.exchange(port: server.boundPort, request: request)
        guard let split = bytes.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: bytes[bytes.startIndex..<split.lowerBound], encoding: .utf8) else {
            throw NSError(domain: "RawClient", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no response head in \(bytes.count) bytes"])
        }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Reply(status: Int(statusLine[1]) ?? 0, headers: headers,
                     body: String(data: bytes[split.upperBound...], encoding: .utf8) ?? "")
    }

    private func send(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") async throws -> Reply {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if !body.isEmpty || method == "PUT" { head += "Content-Length: \(body.utf8.count)\r\n" }
        head += "\r\n"
        return try await raw(Data((head + body).utf8))
    }

    private func webDAV(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") async throws -> Reply {
        try await send(method, path, headers: headers.merging(["User-Agent": Self.webDAVAgent]) { first, _ in first }, body: body)
    }

    private func fileText(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: PROPFIND

    func testPropfindMaskOnlyReturnsWhatWasAsked() async throws {
        try await server.start()
        let reply = try await webDAV("PROPFIND", "/", headers: ["Depth": "0"], body: """
        <D:propfind xmlns:D="DAV:"><D:prop><D:quota-available-bytes/><D:quota-used-bytes/></D:prop></D:propfind>
        """)
        XCTAssertEqual(reply.status, 207)
        XCTAssertTrue(reply.body.contains("<D:quota-available-bytes>"), reply.body)
        XCTAssertTrue(reply.body.contains("<D:quota-used-bytes>"), reply.body)
        XCTAssertFalse(reply.body.contains("getlastmodified"), reply.body)
        XCTAssertFalse(reply.body.contains("<D:quota>"), reply.body)
    }

    func testPropfindEmptyBodyListsEverything() async throws {
        try await server.start()
        let reply = try await webDAV("PROPFIND", "/", headers: ["Depth": "1"])
        XCTAssertEqual(reply.status, 207)
        XCTAssertTrue(reply.body.contains("<D:href>/file.txt</D:href>"), reply.body)
        XCTAssertTrue(reply.body.contains("<D:href>/Folder</D:href>"), reply.body)
        XCTAssertTrue(reply.body.contains("<D:quota>"), reply.body)
        XCTAssertNotNil(reply.body.range(of: "<D:getlastmodified>[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9:]{8} GMT</D:getlastmodified>",
                                         options: .regularExpression), reply.body)
        XCTAssertNotNil(reply.body.range(of: "<D:creationdate>[0-9]{4}-[0-9]{2}-[0-9]{2}T", options: .regularExpression), reply.body)
    }

    func testQuotaAndSupportedLockAreOnCollectionsOnly() async throws {
        try await server.start()
        let reply = try await webDAV("PROPFIND", "/file.txt", headers: ["Depth": "0"])
        XCTAssertEqual(reply.status, 207)
        XCTAssertFalse(reply.body.contains("supportedlock"), reply.body)
        XCTAssertFalse(reply.body.contains("quota"), reply.body)
        XCTAssertTrue(reply.body.contains("getcontenttype"), reply.body)
    }

    func testPropfindCacheIsPerPropertySet() async throws {
        try await server.start()
        _ = try await webDAV("PROPFIND", "/", headers: ["Depth": "0"], body: "<D:prop><D:resourcetype/></D:prop>")
        let second = try await webDAV("PROPFIND", "/", headers: ["Depth": "0"], body: "<D:prop><D:quota-used-bytes/></D:prop>")
        XCTAssertTrue(second.body.contains("quota-used-bytes"), second.body)
        XCTAssertFalse(second.body.contains("resourcetype"), second.body)
    }

    // MARK: LOCK

    func testLockEchoesTheRequest() async throws {
        try await server.start()
        let reply = try await webDAV("LOCK", "/new%20file.bin", headers: ["Depth": "0", "Timeout": "Second-60"], body: """
        <D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>
        """)
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(reply.body.contains("<D:depth>0</D:depth>"), reply.body)
        XCTAssertTrue(reply.body.contains("<D:timeout>Second-60</D:timeout>"), reply.body)
        XCTAssertTrue(reply.body.contains("<D:lockroot><D:href>http://127.0.0.1/new%20file.bin</D:href></D:lockroot>"), reply.body)
        XCTAssertTrue(reply.headers["lock-token"]?.hasPrefix("<urn:uuid:") == true, "\(reply.headers)")
    }

    func testSharedLockAndEscapingLockAreRefused() async throws {
        try await server.start()
        let shared = try await webDAV("LOCK", "/x", body: "<D:lockinfo><D:lockscope><D:shared/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>")
        XCTAssertEqual(shared.status, 403)
        let escape = try await webDAV("LOCK", "/%2e%2e/x")
        XCTAssertEqual(escape.status, 403)
    }

    // MARK: GET and HEAD on collections

    func testRootAndFoldersAnswerOverWebDAV() async throws {
        try await server.start()
        for path in ["/", "/Folder"] {
            let get = try await webDAV("GET", path)
            XCTAssertEqual(get.status, 200, path)
            XCTAssertEqual(get.body, "", path)
            let head = try await webDAV("HEAD", path)
            XCTAssertEqual(head.status, 200, path)
            XCTAssertEqual(head.headers["content-type"], "httpd/unix-directory", path)
            XCTAssertEqual(head.headers["content-length"], "0", path)
        }
        let missing = try await webDAV("GET", "/nope")
        XCTAssertEqual(missing.status, 404)
    }

    // MARK: PUT

    func testPutCreatesThenOverwrites() async throws {
        try await server.start()
        let created = try await webDAV("PUT", "/new.bin", body: "one")
        XCTAssertEqual(created.status, 201)
        let replaced = try await webDAV("PUT", "/new.bin", body: "two")
        XCTAssertEqual(replaced.status, 204)
        XCTAssertEqual(try fileText("new.bin"), "two")
    }

    func testOverwriteFalseLeavesTheFileAlone() async throws {
        try await server.start()
        let refused = try await webDAV("PUT", "/file.txt", headers: ["Overwrite": "F"], body: "new")
        XCTAssertEqual(refused.status, 412)
        XCTAssertEqual(try fileText("file.txt"), "old")
        let allowed = try await webDAV("PUT", "/fresh.bin", headers: ["Overwrite": "F"], body: "new")
        XCTAssertEqual(allowed.status, 201)
    }

    func testChunkedPutHonoursTheSameGate() async throws {
        try await server.start()
        let chunked = { (path: String, extra: String) in
            Data("PUT \(path) HTTP/1.1\r\nHost: x\r\nConnection: close\r\nUser-Agent: \(Self.webDAVAgent)\r\n\(extra)Transfer-Encoding: chunked\r\n\r\n3\r\nnew\r\n0\r\n\r\n".utf8)
        }
        let refused = try await raw(chunked("/file.txt", "Overwrite: F\r\n"))
        XCTAssertEqual(refused.status, 412)
        XCTAssertEqual(try fileText("file.txt"), "old")
        let replaced = try await raw(chunked("/file.txt", ""))
        XCTAssertEqual(replaced.status, 204)
        XCTAssertEqual(try fileText("file.txt"), "new")
    }

    func testBrowserPutStillWorks() async throws {
        try await server.start()
        let reply = try await send("PUT", "/files/browser.bin", headers: ["User-Agent": Self.browserAgent], body: "abc")
        XCTAssertLessThan(reply.status, 300)
        XCTAssertEqual(try fileText("browser.bin"), "abc")
    }

    // MARK: Routes

    func testDoubleSlashReachesRoutesWithTheCollapsedPath() async throws {
        server.addAsyncHandler(forMethod: "GET", path: "/api/thing") { request in
            WebRouteResponse(status: 200, contentType: "text/plain", headers: [:], body: .data(Data(request.path.utf8)))
        }
        try await server.start()
        let reply = try await send("GET", "//api/thing")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.body, "/api/thing")
        let health = try await send("GET", "//api/health")
        XCTAssertEqual(health.status, 200)
    }

    /// An app's access control lives in its route, so a request must not be able to step around
    /// the route by looking like a WebDAV client.
    func testRoutesAnswerWebDAVClientsToo() async throws {
        server.addAsyncHandler(forMethod: "GET", path: "/api/thing") { _ in .error(status: 401, message: "nope") }
        try await server.start()
        let reply = try await webDAV("GET", "/api/thing", headers: ["Depth": "0"])
        XCTAssertEqual(reply.status, 401)
    }

    func testPrefixRouteDispatch() async throws {
        server.addAsyncHandler(forMethod: "POST", pathPrefix: "/api/settings") { request in
            WebRouteResponse(status: 200, contentType: "text/plain", headers: [:], body: .data(Data(request.path.utf8)))
        }
        try await server.start()
        let reply = try await send("POST", "/api/settings/volume", body: "x")
        XCTAssertEqual(reply.body, "/api/settings/volume")
    }

    func testPageRendererReplacesTheBundledPage() async throws {
        server.uploadPageRenderer = { context in "custom:\(context.currentPath):\(context.portSuffix.isEmpty)" }
        try await server.start()
        let reply = try await send("GET", "/?path=Folder", headers: ["User-Agent": Self.browserAgent])
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.body, "custom:Folder:false")
    }

    /// JSONSerialization raises an NSException on NaN, which would take the app down.
    func testUnencodableCustomHandlerResultIs500() async throws {
        server.addCustomHandler(forMethod: "GET", path: "/api/nan") { _, _, _, _ in ["value": Double.nan] }
        try await server.start()
        let reply = try await send("GET", "/api/nan")
        XCTAssertEqual(reply.status, 500)
    }

    // MARK: Request bodies

    func testStalledBodyGets408() async throws {
        server.requestBodyTimeout = 0.2
        server.addAsyncHandler(forMethod: "POST", path: "/api/slow") { _ in .error(status: 500, message: "body should not complete") }
        try await server.start()
        let buffered = try await raw(Data("POST /api/slow HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nabc".utf8))
        XCTAssertEqual(buffered.status, 408)
        let chunked = try await raw(Data("POST /api/slow HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab".utf8))
        XCTAssertEqual(chunked.status, 408)
    }

    func testBodyInTimeIsNotDisturbedByTheDeadline() async throws {
        server.requestBodyTimeout = 0.3
        server.addAsyncHandler(forMethod: "POST", path: "/api/echo") { request in
            WebRouteResponse(status: 200, contentType: "text/plain", headers: [:], body: .data(request.body ?? Data()))
        }
        try await server.start()
        let reply = try await send("POST", "/api/echo", body: "payload")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.body, "payload")
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = try await send("POST", "/api/echo", body: "again")
        XCTAssertEqual(after.body, "again")
    }

    // MARK: Hooks

    func testUploadObserverSeesAPut() async throws {
        final class Recorder: UploadTransfer, @unchecked Sendable {
            let ended = XCTestExpectation(description: "ended")
            private let lock = NSLock()
            private var total = 0
            var written: Int { lock.lock(); defer { lock.unlock() }; return total }
            func didWrite(byteCount: Int) { lock.lock(); total += byteCount; lock.unlock() }
            func didEnd() { ended.fulfill() }
        }
        let recorder = Recorder()
        server.uploadTransferObserver = { recorder }
        try await server.start()
        let reply = try await webDAV("PUT", "/observed.bin", body: "12345")
        XCTAssertEqual(reply.status, 201)
        await fulfillment(of: [recorder.ended], timeout: 5)
        XCTAssertEqual(recorder.written, 5)
    }

    // MARK: Bonjour

    func testBonjourRegistrationReportsTheNameAndCanSkipWebDAV() async throws {
        let box = ResultBox()
        let registered = expectation(description: "registered")
        registered.assertForOverFulfill = false
        server.onBonjourRegistered = { name, port in
            box.name = name
            box.port = port
            registered.fulfill()
        }
        try await server.start()
        let outcome = await XCTWaiter().fulfillment(of: [registered], timeout: 5)
        try XCTSkipIf(outcome != .completed, "no mDNS on this machine")
        XCTAssertTrue(box.name?.hasPrefix(server.bonjourName) == true, "\(String(describing: box.name))")
        XCTAssertEqual(box.port, server.boundPort)
        XCTAssertNil(server.bonjourWebDAV)
    }
}

/// Every app-facing option reaches the engine the tests above drive.
final class WebServerFacadeOptionsTests: XCTestCase {
    private struct NoTransfer: UploadTransfer {
        func didWrite(byteCount: Int) {}
        func didEnd() {}
    }

    private let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unused")

    func testDefaultsKeepTheExistingBehaviour() {
        let engine = PVWebServer(configuration: WebServerConfiguration(rootDirectory: root)).server
        XCTAssertTrue(engine.advertisesWebDAVService)
        XCTAssertFalse(engine.preservesMultipartSubfolders)
        XCTAssertNil(engine.uploadPageRenderer)
        XCTAssertNil(engine.uploadTransferObserver)
    }

    func testOptionsAreForwarded() {
        let engine = PVWebServer(configuration: WebServerConfiguration(
            rootDirectory: root,
            advertisesWebDAVService: false,
            preservesMultipartSubfolders: true,
            uploadPageRenderer: { _ in "page" },
            uploadTransferObserver: { NoTransfer() }
        )).server
        XCTAssertFalse(engine.advertisesWebDAVService)
        XCTAssertTrue(engine.preservesMultipartSubfolders)
        XCTAssertNotNil(engine.uploadPageRenderer)
        XCTAssertNotNil(engine.uploadTransferObserver?())
    }

    func testBonjourHandlerConvertsThePort() {
        let server = PVWebServer(configuration: WebServerConfiguration(rootDirectory: root))
        let box = ResultBox()
        server.setBonjourRegistrationHandler { name, port in
            box.name = name
            box.port = UInt16(port)
        }
        server.server.onBonjourRegistered?("name (2)", 8090)
        XCTAssertEqual(box.name, "name (2)")
        XCTAssertEqual(box.port, 8090)
    }

    func testPrefixRouteReachesTheEngine() async throws {
        let base = 47_000 + Int.random(in: 0..<1_000) * 2
        let server = PVWebServer(configuration: WebServerConfiguration(
            rootDirectory: root, bonjourName: "PVWebServerTest-\(base)",
            preferredPorts: [base, base + 1], advertisesWebDAVService: false
        ))
        server.addAsyncHandler(forMethod: "GET", pathPrefix: "/api/things") { _ in .error(status: 418, message: "tea") }
        try await server.start()
        defer { server.stopServers() }
        let reply = try await RawClient.exchange(
            port: UInt16(server.port),
            request: Data("GET /api/things/one HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8)
        )
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 418"))
    }

    func testSeededAddressIsServedWithoutProbing() {
        let server = PVWebServer(configuration: WebServerConfiguration(rootDirectory: root))
        server.seedCachedIPAddress("192.0.2.7")
        XCTAssertEqual(server.ipAddress, "192.0.2.7")
    }
}

private final class ResultBox: @unchecked Sendable {
    var port: UInt16?
    var name: String?
}

/// One request, then everything the server sends until it closes or `timeout` passes.
private enum RawClient {
    static func exchange(port: UInt16, request: Data, timeout: TimeInterval = 5) async throws -> Data {
        let endpointPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "raw-client")
            let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
            var received = Data()
            var finished = false
            func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    if let data { received.append(data) }
                    if isComplete || error != nil {
                        finish(.success(received))
                    } else {
                        read()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { _ in read() })
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.success(received)) }
        }
    }
}
