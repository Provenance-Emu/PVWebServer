import Darwin
import XCTest
@testable import PVWebServer

/// iFly, iCube and Provenance can share one device and whoever binds a port first
/// owns it, so the app picks its ports and the server reports the one it holds.
final class ROMUploadServerPortTests: XCTestCase {
    private func makeServer() -> ROMUploadServer {
        ROMUploadServer(romsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    }

    func testDefaultsUntilTheAppSetsPorts() {
        let server = makeServer()
        XCTAssertEqual(server.preferredPorts, ROMUploadServer.defaultPorts)
        server.preferredPorts = [8091, 8190]
        XCTAssertEqual(server.preferredPorts, [8091, 8190])
        server.preferredPorts = []
        XCTAssertEqual(server.preferredPorts, ROMUploadServer.defaultPorts, "empty restores the defaults")
    }

    func testBoundPortIsZeroWhileStopped() {
        XCTAssertEqual(makeServer().boundPort, 0)
    }

    func testBusyFirstPortFallsBackAndReportsTheBoundPort() async throws {
        let base = UInt16(43_000 + Int.random(in: 0..<2_000) * 2)
        let hog = try XCTUnwrap(PortHog(port: base))
        defer { hog.close() }
        let server = makeServer()
        server.preferredPorts = [base, base + 1]
        try await server.start()
        XCTAssertEqual(server.boundPort, base + 1)
        server.stop()
        XCTAssertEqual(server.boundPort, 0)
    }
}

/// Holds a port the way another app's listener would.
private final class PortHog {
    private var fd: Int32

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { Darwin.close(fd); return nil }
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }
}
