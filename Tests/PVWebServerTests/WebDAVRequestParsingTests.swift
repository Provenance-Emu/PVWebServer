import XCTest
@testable import PVWebServer

final class WebDAVRequestParsingTests: XCTestCase {
    private func properties(_ xml: String) -> PropfindProperties {
        WebDAVRequestParsing.propfindProperties(Data(xml.utf8))
    }

    func testEmptyBodyAndAllpropMeanEverything() {
        XCTAssertEqual(WebDAVRequestParsing.propfindProperties(Data()), .all)
        XCTAssertEqual(properties("<D:propfind xmlns:D='DAV:'><D:allprop/></D:propfind>"), .all)
    }

    func testUnknownPropertiesFallBackToEverything() {
        XCTAssertEqual(properties("<D:propfind><D:prop><x:weird/></D:prop></D:propfind>"), .all)
    }

    func testNamedPropertiesAreAMask() {
        let mask = properties("<D:prop><D:resourcetype/><D:getcontentlength/></D:prop>")
        XCTAssertEqual(mask, [.resourceType, .contentLength])
        XCTAssertFalse(mask.wantsQuota)
    }

    func testRFC4331QuotaDoesNotImplyMSQuota() {
        let mask = properties("<D:prop><D:quota-available-bytes/><D:quota-used-bytes/></D:prop>")
        XCTAssertEqual(mask, [.quotaAvailable, .quotaUsed])
        XCTAssertTrue(mask.wantsQuota)
    }

    func testMSQuotaMatchesAnyPrefix() {
        XCTAssertEqual(properties("<D:prop><D:quota/><D:quotaused/></D:prop>"), [.msQuota, .msQuotaUsed])
        XCTAssertEqual(properties("<lp1:prop><lp1:quota /></lp1:prop>"), [.msQuota])
        XCTAssertEqual(properties("<prop><quota></quota></prop>"), [.msQuota])
    }

    func testLockRequests() {
        XCTAssertTrue(WebDAVRequestParsing.isSupportedLockRequest(Data()), "a refresh has no body")
        XCTAssertTrue(WebDAVRequestParsing.isSupportedLockRequest(Data(
            "<D:lockinfo><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>".utf8)))
        XCTAssertFalse(WebDAVRequestParsing.isSupportedLockRequest(Data(
            "<D:lockinfo><D:lockscope><D:shared/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>".utf8)))
        XCTAssertFalse(WebDAVRequestParsing.isSupportedLockRequest(Data([0xFF, 0xFE])))
    }

    func testLastModifiedIsRFC1123() {
        XCTAssertEqual(WebDAVRequestParsing.lastModifiedString(Date(timeIntervalSince1970: 784_111_777)),
                       "Sun, 06 Nov 1994 08:49:37 GMT")
    }
}

final class HTTPRequestRoutePathTests: XCTestCase {
    private func routePath(_ path: String) -> String? {
        HTTPRequest.parse("GET \(path) HTTP/1.1\r\nHost: x")?.routePath
    }

    /// iOS and tvOS 18 NSURL joins "/api/x" onto "http://host/" as "//api/x".
    func testLeadingSlashesCollapse() {
        XCTAssertEqual(routePath("//api/x"), "/api/x")
        XCTAssertEqual(routePath("///api/x"), "/api/x")
        XCTAssertEqual(routePath("//"), "/")
    }

    func testOtherPathsAreUntouched() {
        XCTAssertEqual(routePath("/"), "/")
        XCTAssertEqual(routePath("/api/x"), "/api/x")
        XCTAssertEqual(routePath("/ROMs//a.gdi"), "/ROMs//a.gdi")
    }

    func testPathStaysRawForFileRouting() {
        XCTAssertEqual(HTTPRequest.parse("PROPFIND //ROMs HTTP/1.1\r\nHost: x")?.path, "//ROMs")
    }
}

final class WebRouteTablePrefixTests: XCTestCase {
    private func route(_ table: WebRouteTable, _ path: String, method: String = "GET") async -> String? {
        guard let handler = table.handler(forMethod: method, path: path) else { return nil }
        let response = await handler(WebRouteRequest(method: method, path: path, query: [:], headers: [:], body: nil))
        return response.headers["X-Route"]
    }

    private func tagged(_ tag: String) -> WebRouteHandler {
        { _ in WebRouteResponse(status: 200, contentType: "text/plain", headers: ["X-Route": tag], body: .empty) }
    }

    func testPrefixMatchesOnlyBelowASegmentBoundary() async {
        var table = WebRouteTable()
        table.register(method: "GET", pathPrefix: "/api/benchmarks", handler: tagged("prefix"))
        let below = await route(table, "/api/benchmarks/run1")
        let deep = await route(table, "/api/benchmarks/a/b")
        let itself = await route(table, "/api/benchmarks")
        let sibling = await route(table, "/api/benchmarksX/run1")
        let wrongMethod = await route(table, "/api/benchmarks/run1", method: "POST")
        XCTAssertEqual(below, "prefix")
        XCTAssertEqual(deep, "prefix")
        XCTAssertNil(itself)
        XCTAssertNil(sibling)
        XCTAssertNil(wrongMethod)
    }

    func testExactBeatsPrefixInEitherOrder() async {
        var table = WebRouteTable()
        table.register(method: "GET", pathPrefix: "/api", handler: tagged("prefix"))
        table.register(method: "GET", path: "/api/x", handler: tagged("exact"))
        let result = await route(table, "/api/x")
        XCTAssertEqual(result, "exact")
    }

    func testLongestPrefixWinsAndFirstRegistrationStays() async {
        var table = WebRouteTable()
        table.register(method: "GET", pathPrefix: "/api", handler: tagged("short"))
        table.register(method: "GET", pathPrefix: "/api/settings/", handler: tagged("long"))
        XCTAssertFalse(table.register(method: "GET", pathPrefix: "/api/settings", handler: tagged("again")))
        let result = await route(table, "/api/settings/volume")
        XCTAssertEqual(result, "long")
    }
}

final class UploadWriterTests: XCTestCase {
    private final class Recorder: UploadTransfer, @unchecked Sendable {
        private let lock = NSLock()
        private var written = 0
        private var ended = 0
        func didWrite(byteCount: Int) { lock.lock(); written += byteCount; lock.unlock() }
        func didEnd() { lock.lock(); ended += 1; lock.unlock() }
        var counts: (written: Int, ended: Int) { lock.lock(); defer { lock.unlock() }; return (written, ended) }
    }

    func testTransferSeesBytesAndOneEnd() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let writer = try XCTUnwrap(SerialFileWriter(at: url, transfer: recorder))
        writer.write(Data(repeating: 1, count: 10))
        writer.write(Data(repeating: 2, count: 5))
        XCTAssertEqual(writer.bytesWritten, 15, "a write has reached the file by the time it returns")
        let done = expectation(description: "closed")
        writer.finalize { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(recorder.counts.written, 15)
        XCTAssertEqual(recorder.counts.ended, 1)
    }

    func testTransferEndsWhenTheFileCannotOpen() {
        let recorder = Recorder()
        XCTAssertNil(SerialFileWriter(at: URL(fileURLWithPath: "/no/such/dir/file"), transfer: recorder))
        XCTAssertEqual(recorder.counts.ended, 1)
    }
}

final class MultipartPathTests: XCTestCase {
    private func path(_ name: String, preserve: Bool) -> String? {
        StreamingMultipartParser.sanitizedRelativePath(name, preservesSubfolders: preserve)
    }

    func testDefaultFlattens() {
        XCTAssertEqual(path("set/disc.chd", preserve: false), "disc.chd")
        XCTAssertEqual(path("disc.chd", preserve: false), "disc.chd")
    }

    func testPreservingKeepsTheFolderPath() {
        XCTAssertEqual(path("meltybld/gdl-0028c.chd", preserve: true), "meltybld/gdl-0028c.chd")
        XCTAssertEqual(path("./a//b.bin", preserve: true), "a/b.bin")
    }

    func testPreservingRejectsTraversalAndHiddenComponents() {
        XCTAssertNil(path("../escape.bin", preserve: true))
        XCTAssertNil(path("a/../../escape.bin", preserve: true))
        XCTAssertNil(path(".hidden/x.bin", preserve: true))
        XCTAssertNil(path("a/.DS_Store", preserve: true))
        XCTAssertNil(path("", preserve: true))
    }

    func testFlatteningStillDropsHiddenAndTraversalNames() {
        XCTAssertNil(path(".DS_Store", preserve: false))
        XCTAssertNil(path("..", preserve: false))
    }
}

final class WebServerLogTests: XCTestCase {
    func testHandlerReceivesLevelAndMessage() {
        let received = expectation(description: "logged")
        WebServerLog.setHandler { level, message in
            guard message == "hello" else { return }
            XCTAssertEqual(level, .warning)
            received.fulfill()
        }
        defer { WebServerLog.setHandler(nil) }
        WebServerLog.log(.warning, "hello")
        wait(for: [received], timeout: 1)
    }
}

final class BenignConnectionErrorTests: XCTestCase {
    func testResetIsBenignAtAnyDepth() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 54)
        XCTAssertTrue(ROMUploadServer.isBenignConnectionError(posix))
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertTrue(ROMUploadServer.isBenignConnectionError(wrapped))
    }

    func testOtherErrorsAreNot() {
        XCTAssertFalse(ROMUploadServer.isBenignConnectionError(NSError(domain: NSPOSIXErrorDomain, code: 28)))
        XCTAssertFalse(ROMUploadServer.isBenignConnectionError(NSError(domain: "Other", code: 54)))
    }
}
