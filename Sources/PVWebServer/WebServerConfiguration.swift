//
//  WebServerConfiguration.swift
//  PVWebServer
//
//  What an app decides about its server: where it serves from, what it calls itself and
//  which ports it tries. `PVWebServer.shared` keeps iCube's values; any other app builds
//  its own instance with `PVWebServer(configuration:)`.
//

import Foundation

public struct WebServerConfiguration: Sendable {
    /// The folder the browser UI and WebDAV serve. Created if it does not exist.
    public var rootDirectory: URL
    /// Where `POST /upload` writes when the request has no `path` query. `nil` means the root.
    public var defaultUploadDirectory: URL?
    /// Title of the built-in upload page. `nil` uses the host app's display name.
    public var pageTitle: String?
    /// Bonjour instance name for `_http._tcp` and `_webdav._tcp`. Two devices advertising one
    /// name collide and the second never publishes, so `nil` uses "<title> (<host name>)".
    public var bonjourName: String?
    /// Ports tried in order until one binds. Empty uses the package defaults.
    public var preferredPorts: [Int]
    /// Post iCube's library notifications (`DOLImportFileFinishedNotification`, `DOLShowSnackbar`)
    /// after a burst of uploads, and run the post-processor set with `setUploadPostProcessor`.
    /// Apps that observe the upload notifications themselves turn this off.
    public var bridgesUploadsToLibraryRescan: Bool
    /// Also post the upload-completed notification for files a WebDAV MOVE lands at. Leave on
    /// if uploads are what drives your library rescan; turn off if you handle the moved
    /// notification, or a rename looks like a new file arriving.
    public var reportsWebDAVMovesAsUploads: Bool
    /// Publish `_webdav._tcp` alongside the listener's `_http._tcp`. Turn it off when the app
    /// advertises WebDAV itself: two registrations of one name and type collide with -72001.
    public var advertisesWebDAVService: Bool
    /// Keep the sender's folder path in multipart uploads ("set/disc.chd" lands in `set/`) rather
    /// than flattening to the file name. Traversal and hidden components are refused either way.
    public var preservesMultipartSubfolders: Bool
    /// Replaces the bundled upload page at `GET /`, keeping the folder listing the server builds.
    /// Called off the main thread, possibly from several connections at once.
    public var uploadPageRenderer: (@Sendable (UploadPageContext) -> String)?
    /// Called once per uploaded file when its writer opens. Return a transfer to observe the
    /// bytes reaching disk, or nil to skip this file.
    public var uploadTransferObserver: (@Sendable () -> (any UploadTransfer)?)?
    /// One result per accepted file target, including failed opens. Called off the main
    /// thread after publication or cleanup. Keep it short and thread-safe.
    public var onUploadResult: (@Sendable (UploadResult) -> Void)?

    public init(
        rootDirectory: URL,
        defaultUploadDirectory: URL? = nil,
        pageTitle: String? = nil,
        bonjourName: String? = nil,
        preferredPorts: [Int] = [],
        bridgesUploadsToLibraryRescan: Bool = false,
        reportsWebDAVMovesAsUploads: Bool = true,
        advertisesWebDAVService: Bool = true,
        preservesMultipartSubfolders: Bool = false,
        uploadPageRenderer: (@Sendable (UploadPageContext) -> String)? = nil,
        uploadTransferObserver: (@Sendable () -> (any UploadTransfer)?)? = nil,
        onUploadResult: (@Sendable (UploadResult) -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.defaultUploadDirectory = defaultUploadDirectory
        self.pageTitle = pageTitle
        self.bonjourName = bonjourName
        self.preferredPorts = preferredPorts
        self.bridgesUploadsToLibraryRescan = bridgesUploadsToLibraryRescan
        self.reportsWebDAVMovesAsUploads = reportsWebDAVMovesAsUploads
        self.advertisesWebDAVService = advertisesWebDAVService
        self.preservesMultipartSubfolders = preservesMultipartSubfolders
        self.uploadPageRenderer = uploadPageRenderer
        self.uploadTransferObserver = uploadTransferObserver
        self.onUploadResult = onUploadResult
    }
}
