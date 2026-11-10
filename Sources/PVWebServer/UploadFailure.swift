// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  UploadFailure.swift
//  PVWebServer
//
//  Why a finished upload must not be reported as success. Pure so it is testable
//  without a socket.

import Foundation

enum UploadFailure: Error, Equatable {
    case diskFull
    case writeError
    /// The socket closed before `Content-Length` bytes arrived.
    case truncated
    case invalidBody
    case destinationExists
    case destinationIsDirectory

    var httpStatus: Int {
        switch self {
        case .diskFull: return 507
        case .invalidBody: return 400
        case .destinationExists: return 412
        case .destinationIsDirectory: return 405
        case .writeError, .truncated: return 500
        }
    }

    var statusText: String {
        switch self {
        case .diskFull: return "Insufficient Storage"
        case .invalidBody: return "Bad Request"
        case .destinationExists: return "Precondition Failed"
        case .destinationIsDirectory: return "Method Not Allowed"
        case .writeError, .truncated: return "Internal Server Error"
        }
    }

    var logReason: String {
        switch self {
        case .diskFull: return "disk full"
        case .writeError: return "write error"
        case .truncated: return "connection closed before the upload ended"
        case .invalidBody: return "Invalid upload body"
        case .destinationExists: return "Target exists"
        case .destinationIsDirectory: return "Target is a folder"
        }
    }

    var outcome: UploadOutcome {
        switch self {
        case .diskFull: return .diskFull
        case .writeError: return .writeFailed
        case .truncated: return .cancelled
        case .invalidBody: return .invalidBody
        case .destinationExists: return .destinationExists
        case .destinationIsDirectory: return .destinationIsDirectory
        }
    }

    static func diskFailure(errno: Int32) -> UploadFailure {
        errno == ENOSPC || errno == EDQUOT ? .diskFull : .writeError
    }

    static func diskFailure(_ error: Error) -> UploadFailure {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return diskFailure(errno: Int32(clamping: ns.code)) }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return .diskFull }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== ns {
            return diskFailure(underlying)
        }
        return .writeError
    }

    /// Call only after the writer has closed.
    static func classify(writer: SerialFileWriter, truncated: Bool) -> UploadFailure? {
        if writer.failed { return writer.diskFull ? .diskFull : .writeError }
        if truncated { return .truncated }
        return nil
    }
}
