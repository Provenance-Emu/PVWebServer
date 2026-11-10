import XCTest
@testable import PVWebServer

final class StagedUploadTests: XCTestCase {
    func testNoOverwriteIsEnforcedAtCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("disc.iso")
        let first = try StagedUpload.open(at: destination, observer: nil, onResult: nil).get()
        let second = try StagedUpload.open(at: destination, observer: nil, onResult: nil).get()
        first.write(Data("first".utf8))
        second.write(Data("second".utf8))

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(first.finish(overwrite: false))
        XCTAssertEqual(second.finish(overwrite: false), .destinationExists)
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["disc.iso"])
    }
}
