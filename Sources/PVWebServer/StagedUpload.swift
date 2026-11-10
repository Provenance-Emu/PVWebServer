import Darwin
import Foundation

/// One file transfer. The caller serializes writes and completion, as for SerialFileWriter.
final class StagedUpload: @unchecked Sendable {
    static let stagingPrefix = ".pvweb-upload-"

    private let id: UUID
    let destination: URL
    private let stagingURL: URL
    private let writer: SerialFileWriter
    private let onResult: (@Sendable (UploadResult) -> Void)?
    private var finished = false

    private init(id: UUID, destination: URL, stagingURL: URL, writer: SerialFileWriter,
                 onResult: (@Sendable (UploadResult) -> Void)?) {
        self.id = id
        self.destination = destination
        self.stagingURL = stagingURL
        self.writer = writer
        self.onResult = onResult
    }

    static func open(
        at destination: URL,
        observer: (() -> (any UploadTransfer)?)?,
        onResult: (@Sendable (UploadResult) -> Void)?
    ) -> Result<StagedUpload, UploadFailure> {
        let id = UUID()
        let parent = destination.deletingLastPathComponent()
        func refuse(_ failure: UploadFailure) -> Result<StagedUpload, UploadFailure> {
            onResult?(UploadResult(id: id, destination: destination, bytesWritten: 0, outcome: failure.outcome))
            return .failure(failure)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return refuse(.destinationIsDirectory)
        }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return refuse(UploadFailure.diskFailure(error))
        }
        let template = parent.appendingPathComponent(stagingPrefix + "XXXXXX").path
        var path = Array(template.utf8CString)
        let descriptor = mkstemp(&path)
        guard descriptor >= 0 else { return refuse(UploadFailure.diskFailure(errno: errno)) }
        let stagingURL = URL(fileURLWithPath: String(cString: path))
        let writer = SerialFileWriter(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                                      transfer: observer?())
        return .success(StagedUpload(id: id, destination: destination, stagingURL: stagingURL,
                                     writer: writer, onResult: onResult))
    }

    func write(_ data: Data) { writer.write(data) }

    /// Close before publishing. Same-directory rename is atomic and leaves an existing
    /// destination intact on failure. RENAME_EXCL enforces no-overwrite at publication.
    func finish(failure inputFailure: UploadFailure? = nil, overwrite: Bool = true,
                discard: Bool = false) -> UploadFailure? {
        precondition(!finished)
        writer.close()
        let writerFailure = UploadFailure.classify(writer: writer, truncated: false)
        var failure = writerFailure ?? inputFailure
        if failure == nil, !discard {
            let status = overwrite
                ? rename(stagingURL.path, destination.path)
                : renamex_np(stagingURL.path, destination.path, UInt32(RENAME_EXCL))
            if status != 0 {
                let code = errno
                switch code {
                case EEXIST: failure = overwrite ? .writeError : .destinationExists
                case EISDIR: failure = .destinationIsDirectory
                default: failure = UploadFailure.diskFailure(errno: code)
                }
            }
        }
        if failure != nil || discard { try? FileManager.default.removeItem(at: stagingURL) }
        finished = true
        report(failure?.outcome ?? (discard ? .discardedMetadata : .completed))
        return failure
    }

    deinit {
        // A server disappearing with a live connection still owns its staging file.
        if !finished {
            writer.close()
            try? FileManager.default.removeItem(at: stagingURL)
            report(.cancelled)
        }
    }

    private func report(_ outcome: UploadOutcome) {
        onResult?(UploadResult(id: id, destination: destination, bytesWritten: writer.bytesWritten, outcome: outcome))
    }
}
