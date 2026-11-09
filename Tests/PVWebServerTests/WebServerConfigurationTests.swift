import XCTest
@testable import PVWebServer

/// Runs a configured server on a real port, the way an app other than iCube uses it.
final class WebServerConfigurationTests: XCTestCase {
    private var root: URL!
    private var server: PVWebServer!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stopServers()
        try? FileManager.default.removeItem(at: root)
    }

    private func start(
        defaultUpload: String? = nil,
        reportsMoves: Bool = true
    ) async throws {
        let base = 46_000 + Int.random(in: 0..<4_000)
        server = PVWebServer(configuration: WebServerConfiguration(
            rootDirectory: root,
            defaultUploadDirectory: defaultUpload.map { root.appendingPathComponent($0) },
            pageTitle: "Test",
            bonjourName: "Test \(UUID().uuidString.prefix(8))",
            preferredPorts: [base, base + 1, base + 2],
            reportsWebDAVMovesAsUploads: reportsMoves
        ))
        try await server.start()
        XCTAssertTrue(server.isRunning)
    }

    private func request(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(server.port)\(path)") else {
            preconditionFailure("Bad test path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, data)
    }

    private func write(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("rom".utf8).write(to: url)
        return url
    }

    private func multipart(filename: String) -> (headers: [String: String], body: Data) {
        let boundary = "TestBoundary"
        let body = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\nrom\r\n--\(boundary)--\r\n"
        return (["Content-Type": "multipart/form-data; boundary=\(boundary)"], Data(body.utf8))
    }

    /// Collects `name` notifications while `work` runs.
    private func notes(named name: String, during work: () async throws -> Void) async rethrows -> [[AnyHashable: Any]] {
        let box = NoteBox()
        let token = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { note in
            box.append(note.userInfo ?? [:])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await work()
        return box.values
    }

    // MARK: Upload destination

    func testUploadWithoutPathGoesToTheDefaultDirectory() async throws {
        try await start(defaultUpload: "Imports")
        let form = multipart(filename: "game.bin")
        let result = try await send(request("POST", "/upload", headers: form.headers, body: form.body))
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Imports/game.bin").path))
    }

    func testUploadWithPathIgnoresTheDefaultDirectory() async throws {
        try await start(defaultUpload: "Imports")
        let form = multipart(filename: "game.bin")
        try await send(request("POST", "/upload?path=Save%20States", headers: form.headers, body: form.body))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Save States/game.bin").path))
    }

    // MARK: File change notifications

    func testWebDAVDeletePostsTheAbsolutePath() async throws {
        try await start()
        let file = try write("ROMs/game.bin")
        let posted = try await notes(named: PVWebServerFileDeletedNotificationName) {
            let result = try await send(request("DELETE", "/ROMs/game.bin"))
            XCTAssertEqual(result.status, 204)
        }
        XCTAssertEqual(posted.map { $0["filePath"] as? String }, [file.standardized.path])
    }

    func testBrowserDeletePostsTheAbsolutePath() async throws {
        try await start()
        let file = try write("ROMs/game.bin")
        let posted = try await notes(named: PVWebServerFileDeletedNotificationName) {
            try await send(request("DELETE", "/files/ROMs/game.bin"))
        }
        XCTAssertEqual(posted.map { $0["filePath"] as? String }, [file.standardized.path])
    }

    func testDeletingAFinderSidecarPostsNothing() async throws {
        try await start()
        _ = try write("ROMs/._game.bin")
        let posted = try await notes(named: PVWebServerFileDeletedNotificationName) {
            try await send(request("DELETE", "/ROMs/._game.bin"))
        }
        XCTAssertTrue(posted.isEmpty)
    }

    func testWebDAVMovePostsMovedAndCanStayOutOfTheUploadStream() async throws {
        try await start(reportsMoves: false)
        let source = try write("ROMs/old.bin")
        let destination = "http://127.0.0.1:\(server.port)/ROMs/new.bin"
        var moved: [[AnyHashable: Any]] = []
        let uploads = try await notes(named: PVWebServerFileUploadCompletedNotificationName) {
            moved = try await notes(named: PVWebServerFileMovedNotificationName) {
                try await send(request("MOVE", "/ROMs/old.bin", headers: ["Destination": destination]))
            }
        }
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?["fromPath"] as? String, source.standardized.path)
        XCTAssertEqual(moved.first?["toPath"] as? String, root.appendingPathComponent("ROMs/new.bin").standardized.path)
        XCTAssertTrue(uploads.isEmpty)
    }

    func testWebDAVMoveStillReportsAnUploadByDefault() async throws {
        try await start()
        _ = try write("ROMs/old.bin")
        let destination = "http://127.0.0.1:\(server.port)/ROMs/new.bin"
        let uploads = try await notes(named: PVWebServerFileUploadCompletedNotificationName) {
            try await send(request("MOVE", "/ROMs/old.bin", headers: ["Destination": destination]))
        }
        XCTAssertEqual(uploads.count, 1, "iCube's library rescan depends on this")
    }

    func testBrowserMovePostsMoved() async throws {
        try await start()
        _ = try write("ROMs/old.bin")
        let body = try JSONSerialization.data(withJSONObject: ["src": "ROMs/old.bin", "dst": "ROMs/new.bin"])
        let moved = try await notes(named: PVWebServerFileMovedNotificationName) {
            try await send(request("POST", "/move", body: body))
        }
        XCTAssertEqual(moved.count, 1)
    }

    func testCreatingAFolderPostsItsPath() async throws {
        try await start()
        let dav = try await notes(named: PVWebServerFolderCreatedNotificationName) {
            try await send(request("MKCOL", "/Saves"))
        }
        XCTAssertEqual(dav.map { $0["filePath"] as? String }, [root.appendingPathComponent("Saves").standardized.path])

        let body = try JSONSerialization.data(withJSONObject: ["path": "More"])
        let browser = try await notes(named: PVWebServerFolderCreatedNotificationName) {
            try await send(request("POST", "/mkdir", body: body))
        }
        XCTAssertEqual(browser.count, 1)
    }

    // MARK: Routes

    func testRegisteredRouteReplacesTheBuiltInPageAndSeesHeaders() async throws {
        try await start()
        server.addAsyncHandler(forMethod: "GET", path: "/") { request in
            WebRouteResponse(status: 200, contentType: "text/plain", body: .data(Data((request.header("X-Test") ?? "").utf8)))
        }
        let result = try await send(request("GET", "/", headers: ["X-Test": "seen"]))
        XCTAssertEqual(String(data: result.body, encoding: .utf8), "seen")
    }

    func testStreamRouteDeliversEveryWriteAndClosesWhenItReturns() async throws {
        try await start()
        server.addAsyncHandler(forMethod: "GET", path: "/events") { _ in
            WebRouteResponse(status: 200, contentType: "text/event-stream", body: .stream { writer in
                await writer.write(Data("one\n".utf8))
                await writer.write(Data("two\n".utf8))
            })
        }
        let result = try await send(request("GET", "/events"))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(String(data: result.body, encoding: .utf8), "one\ntwo\n")
    }

    func testStreamWriterReportsAClientThatWentAway() async throws {
        try await start()
        let gone = expectation(description: "a write failed after the client left")
        server.addAsyncHandler(forMethod: "GET", path: "/events") { _ in
            WebRouteResponse(status: 200, contentType: "text/event-stream", body: .stream { writer in
                while await writer.write(Data("tick\n".utf8)) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                gone.fulfill()
            })
        }
        let (bytes, _) = try await URLSession.shared.bytes(for: request("GET", "/events"))
        for try await line in bytes.lines {
            XCTAssertEqual(line, "tick")
            break
        }
        bytes.task.cancel()
        await fulfillment(of: [gone], timeout: 10)
    }

    // MARK: Unexpected stop

    /// iOS killing the socket of a suspended app looks like this to the server.
    private func killListener() throws {
        try XCTUnwrap(server.server.listener).cancel()
    }

    func testADeadListenerStopsTheServerAndCallsTheHandler() async throws {
        try await start()
        let stopped = expectation(description: "unexpected stop reported")
        server.setUnexpectedStopHandler { stopped.fulfill() }
        try killListener()
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(server.port, 0)
    }

    func testTheServerCanStartAgainAfterADeadListener() async throws {
        try await start()
        let stopped = expectation(description: "unexpected stop reported")
        server.setUnexpectedStopHandler { stopped.fulfill() }
        try killListener()
        await fulfillment(of: [stopped], timeout: 5)
        try await server.start()
        XCTAssertTrue(server.isRunning)
        XCTAssertNotEqual(server.port, 0)
    }

    func testARequestedStopDoesNotCallTheHandler() async throws {
        try await start()
        let stopped = expectation(description: "no unexpected stop")
        stopped.isInverted = true
        server.setUnexpectedStopHandler { stopped.fulfill() }
        server.stopServers()
        await fulfillment(of: [stopped], timeout: 1)
    }
}

private final class NoteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[AnyHashable: Any]] = []

    func append(_ value: [AnyHashable: Any]) {
        lock.lock(); defer { lock.unlock() }
        stored.append(value)
    }

    var values: [[AnyHashable: Any]] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
