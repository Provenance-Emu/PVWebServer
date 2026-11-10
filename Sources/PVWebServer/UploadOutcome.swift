import Foundation

/// The terminal disposition of one accepted upload target.
public enum UploadOutcome: Sendable, Equatable {
    /// The complete file is now visible at the destination.
    case completed
    /// Finder metadata was accepted and discarded without publishing a file.
    case discardedMetadata
    case cancelled
    case invalidBody
    case diskFull
    case writeFailed
    case destinationExists
    case destinationIsDirectory
}

/// A single PUT or multipart file part, after publication or cleanup.
public struct UploadResult: Sendable, Equatable {
    public let id: UUID
    public let destination: URL
    public let bytesWritten: Int
    public let outcome: UploadOutcome
}
