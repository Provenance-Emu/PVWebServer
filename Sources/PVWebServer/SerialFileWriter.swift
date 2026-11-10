// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  SerialFileWriter.swift
//  PVWebServer
//
//  Writes to a per-file serial queue and waits for each write, which holds the next
//  `NWConnection.receive` back until flash has caught up. TCP backpressure then slows
//  the sender: queueing writes instead let a multi-hundred-MB upload grow RSS one read
//  at a time. Records write and close failures: a disk-full upload used to truncate the
//  file while the client got a 2xx, so callers MUST consult `failed` before reporting
//  success.

import Foundation

final class SerialFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue

    /// A write or close threw. Read only after `finalize`'s completion has run.
    private(set) var failed = false
    /// The failure was ENOSPC, so the caller can answer 507.
    private(set) var diskFull = false
    private(set) var bytesWritten = 0

    private let transfer: (any UploadTransfer)?

    init?(at url: URL, transfer: (any UploadTransfer)? = nil) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            transfer?.didEnd()
            return nil
        }
        self.handle = handle
        self.queue = Self.makeQueue()
        self.transfer = transfer
    }

    init(handle: FileHandle, transfer: (any UploadTransfer)? = nil) {
        self.handle = handle
        self.queue = Self.makeQueue()
        self.transfer = transfer
    }

    private static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "org.dolphin.iCube.uploadserver.disk.\(UUID().uuidString)", qos: .utility)
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.sync {
            guard !self.failed else { return }
            do {
                try self.handle.write(contentsOf: data)
                self.bytesWritten += data.count
                self.transfer?.didWrite(byteCount: data.count)
            } catch {
                self.recordFailure(error, context: "write after \(self.bytesWritten) bytes")
            }
        }
    }

    func close() {
        queue.sync {
            do {
                try handle.close()
            } catch {
                if !failed { recordFailure(error, context: "close") }
            }
            transfer?.didEnd()
        }
    }

    func finalize(completion: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.close()
            completion()
        }
    }

    private func recordFailure(_ error: Error, context: String) {
        failed = true
        diskFull = UploadFailure.diskFailure(error) == .diskFull
        WebServerLog.log(.error, "upload \(context) failed\(diskFull ? " (disk full)" : ""): \(error)")
    }
}
