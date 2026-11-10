// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  PVWebServer.swift
//  PVWebServer
//
//  Swift facade preserving the historical `PVWebServer.shared` ObjC API while
//  swapping the engine from the vendored 2015 GCDWebServer / GCDWebUploader /
//  GCDWebDAVServer stack to the dependency-free NWListener-based
//  `ROMUploadServer` (ported from iFly).
//
//  The class is `@objc(PVWebServer)` and reproduces the exact Swift-visible
//  names the existing call sites use:
//      PVWebServer.shared.startServers()       (TVRootView)
//      PVWebServer.shared.stopServers()
//      PVWebServer.shared.urlString            (SettingsRootView)
//      PVWebServer.shared.webDavURLString      (SettingsRootView)
//      PVWebServer.shared.ipAddress            (SourcesView)
//      PVWebServer.shared.bonjourSeverURL      (SourcesView — note historical
//                                               spelling "Sever")
//  …so none of those call sites need to change.
//
//  IMPORT/RESCAN BRIDGE — historically the GCDWebServer stack uploaded files
//  straight into the documents directory and posted
//  PVWebServerFileUploadCompletedNotification, but nothing in iCube observed
//  that notification, so a web upload did NOT auto-refresh the library; the
//  game only appeared on the next manual reload. This facade closes that gap:
//  it observes its own completion notification, debounces a multi-file burst,
//  then posts DOLImportFileFinishedNotification (the rescan trigger the library
//  already listens for) plus a DOLShowSnackbar toast. This is an ADDED
//  improvement over the old behavior, not a regression.

import Foundation

// MARK: - Notification name constants (string-identical to the old ObjC ones)

/// Posted when a file upload begins. userInfo: ["path": String].
public let PVWebServerFileUploadStartedNotificationName = "PVWebServerFileUploadStartedNotification"

/// Posted by any UI whose purpose is the server itself -- the Wi-Fi import sheet,
/// Settings' network page. Asking to see the upload address IS asking for the
/// server, so the lifecycle policy starts it on demand and holds it up for as long
/// as that surface is on screen, outranking the pause-during-emulation rule.
/// Balance every post of these with the Released one.
public let PVWebServerUserAccessRequestedNotificationName = "PVWebServerUserAccessRequestedNotification"
public let PVWebServerUserAccessReleasedNotificationName = "PVWebServerUserAccessReleasedNotification"
/// Posted when a file upload completes. userInfo: ["filePath": String, "fileSize": UInt64].
public let PVWebServerFileUploadCompletedNotificationName = "PVWebServerFileUploadCompletedNotification"
/// Posted after a client deletes a file or folder (browser UI or WebDAV).
/// userInfo: ["filePath": String], absolute path of what was deleted.
public let PVWebServerFileDeletedNotificationName = "PVWebServerFileDeletedNotification"
/// Posted after a client moves or renames a file or folder (browser UI or WebDAV).
/// userInfo: ["fromPath": String, "toPath": String], both absolute.
public let PVWebServerFileMovedNotificationName = "PVWebServerFileMovedNotification"
/// Posted after a client creates a folder (browser UI or WebDAV).
/// userInfo: ["filePath": String], absolute path of the new folder.
public let PVWebServerFolderCreatedNotificationName = "PVWebServerFolderCreatedNotification"

/// ObjC-visible Notification.Name accessors (kept for any ObjC observers that
/// referenced the old `extern NSString* const` symbols).
@objc public extension NSNotification {
    static var pvWebServerFileUploadStartedName: String { PVWebServerFileUploadStartedNotificationName }
    static var pvWebServerFileUploadCompletedName: String { PVWebServerFileUploadCompletedNotificationName }
}

// MARK: - PVWebServer

@objc(PVWebServer)
public final class PVWebServer: NSObject, @unchecked Sendable {

    // MARK: Singleton

    @objc(sharedInstance)
    public static let shared = PVWebServer()

    // MARK: Engine

    let server: ROMUploadServer
    private var rescanWorkItem: DispatchWorkItem?
    private var pendingUploadCount = 0
    /// Uploads that have posted Started but not yet Completed. A WebDAV copy is several
    /// requests (Finder writes the `._` AppleDouble sidecar first, Windows pre-creates a
    /// zero-byte file), so "a completion arrived" is not "the copy is done"; the rescan waits
    /// until nothing is still being written, or the library indexes a half-written ROM.
    private var uploadsInFlight = 0
    private var lastUploadActivity = Date.distantPast
    private static let rescanDebounce: TimeInterval = 1.5
    private static let rescanRecheck: TimeInterval = 2.0
    /// A failed upload deletes its partial file without posting Completed, which would pin
    /// `uploadsInFlight` above zero forever. If nothing has started or finished for this long,
    /// the count is treated as stale and the rescan runs anyway.
    private static let uploadActivityStaleAfter: TimeInterval = 120
    /// Optional hook for the app target to post-process uploads (e.g. archive extraction).
    private var uploadPostProcessor: ((String) -> Void)?
    /// Optional hook returning custom snackbar text for a debounced upload burst (`nil` → default).
    private var uploadSummaryProvider: ((Int) -> String?)?

    // MARK: Init

    /// iCube's server: the `shared` instance, serving the library scanner's folder.
    private override convenience init() {
        self.init(configuration: WebServerConfiguration(
            rootDirectory: PVWebServer.uploadRootDirectory(),
            bridgesUploadsToLibraryRescan: true
        ))
    }

    /// A server for an app that decides its own folder, names and ports. Nothing runs until
    /// `start()`. Routes added with `addAsyncHandler` survive stop and start.
    public init(configuration: WebServerConfiguration) {
        self.server = ROMUploadServer(romsDirectory: configuration.rootDirectory)
        super.init()

        // Title shown on the upload web page.
        let title = configuration.pageTitle
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "iCube"
        self.server.pageTitle = title
        // Unique per device so two iCubes on one LAN do not collide on the Bonjour name.
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        self.server.bonjourName = configuration.bonjourName ?? (host.isEmpty ? title : "\(title) (\(host))")
        self.server.defaultUploadDirectory = configuration.defaultUploadDirectory
        self.server.reportsWebDAVMovesAsUploads = configuration.reportsWebDAVMovesAsUploads
        self.server.advertisesWebDAVService = configuration.advertisesWebDAVService
        self.server.preservesMultipartSubfolders = configuration.preservesMultipartSubfolders
        self.server.uploadPageRenderer = configuration.uploadPageRenderer
        self.server.uploadTransferObserver = configuration.uploadTransferObserver
        self.server.onUploadResult = configuration.onUploadResult
        self.preferredPorts = configuration.preferredPorts

        guard configuration.bridgesUploadsToLibraryRescan else { return }

        // Bridge upload completion → library rescan + toast.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUploadStarted(_:)),
            name: Notification.Name(PVWebServerFileUploadStartedNotificationName),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUploadCompleted(_:)),
            name: Notification.Name(PVWebServerFileUploadCompletedNotificationName),
            object: nil
        )
    }

    // MARK: Upload root directory

    /// The directory the upload server serves / writes into. Rooted at the
    /// `Software` subfolder — the EXACT directory the library scanner reads
    /// (`UserFolderUtil.getSoftwareFolder` = `<user folder>/Software`, where the
    /// user folder is Documents on iOS / Caches on tvOS, same as computed here).
    /// Previously this returned the user-folder ROOT, so a default drag-and-drop
    /// upload landed one level ABOVE where the scanner looks and never appeared
    /// in the library unless the user manually navigated into `Software` first.
    /// `ROMUploadServer.init` creates this directory if it doesn't exist yet.
    private static func uploadRootDirectory() -> URL {
        #if os(tvOS)
        let base = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        #else
        let base = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        #endif
        return URL(fileURLWithPath: base).appendingPathComponent("Software")
    }

    // MARK: - Lifecycle

    /// Binds the first free port in `preferredPorts` and returns once the listener is ready.
    /// Throws if none binds. Does nothing if the server is already up.
    public func start() async throws {
        try await server.start()
    }

    /// Whether the listener is up. Also covers WebDAV, which shares it.
    public var isRunning: Bool { server.isRunning }

    /// Called when a running listener dies without `stopServers()`, which is what iOS does to
    /// the sockets of a suspended app. The server has already stopped itself and withdrawn its
    /// Bonjour records; call `start()` to come back, possibly on another port. Runs on a
    /// private queue.
    public func setUnexpectedStopHandler(_ handler: (@Sendable () -> Void)?) {
        server.unexpectedStopHandler = handler
    }

    /// Called with the name and port `_http._tcp` actually registered under. mDNSResponder renames
    /// on conflict ("iFly EMU (2)"), so anything else advertised for this server has to follow
    /// this name, not the configured one. Set before `start()`. Runs on a private queue.
    public func setBonjourRegistrationHandler(_ handler: (@Sendable (_ name: String, _ port: Int) -> Void)?) {
        server.onBonjourRegistered = handler.map { handler in { name, port in handler(name, Int(port)) } }
    }

    /// Seeds the LAN address after probing it off the main thread, so `ipAddress` and the upload
    /// page never walk the network interfaces on the caller's thread. Cleared by a stop.
    public func seedCachedIPAddress(_ ip: String) {
        server.seedCachedIPAddress(ip)
    }

    // MARK: - Public ObjC API (legacy surface)

    @discardableResult
    @objc public func startServers() -> Bool {
        guard !server.isRunning else { return true }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.server.start()
                NSLog("[PVWebServer] Started web server at \(self.server.serverURL?.absoluteString ?? "?") (HTTP + WebDAV on one port)")
            } catch {
                NSLog("[PVWebServer] Failed to start web server: \(error.localizedDescription)")
            }
        }
        return true
    }

    @objc public func stopServers() {
        server.stop()
    }

    @discardableResult
    @objc public func startWWWUploadServer() -> Bool { return startServers() }

    @objc public func stopWWWUploadServer() { stopServers() }

    @discardableResult
    @objc public func startWebDavServer() -> Bool { return startServers() }

    @objc public func stopWebDavServer() { stopServers() }

    @objc public var isWWWUploadServerRunning: Bool { server.isRunning }
    @objc public var isWebDavServerRunning: Bool { server.isRunning }

    /// Local IPv4 address of the device (en0/en1), or nil.
    @objc(IPAddress)
    public var ipAddress: String? { server.ipAddress }

    /// HTTP upload-UI URL string (e.g. `http://192.168.1.5/`), or nil if down.
    @objc(URLString)
    public var urlString: String? { server.serverURL?.absoluteString }

    /// WebDAV URL string (e.g. `http://192.168.1.5/`), or nil if down. HTTP and WebDAV
    /// now share one listener/port, so this is the same URL as `urlString`.
    @objc(WebDavURLString)
    public var webDavURLString: String? { server.serverURL?.absoluteString }

    /// HTTP upload-UI URL, or nil if down.
    @objc(URL)
    public var url: URL? { server.serverURL }

    /// The port the listener holds right now, or 0 while it is down. Read this, not
    /// `url?.port`, which is nil for `http://ip/` (port 80).
    @objc public var port: Int { Int(server.boundPort) }

    /// Ports the next start tries, in order (HTTP and WebDAV share one listener). Set it
    /// before the first start. Empty restores the defaults (80, 8080, 8000, 8888, 9000 on
    /// device). Ports outside 1...65535 are dropped.
    @objc public var preferredPorts: [Int] {
        get { server.preferredPorts.map(Int.init) }
        set { server.preferredPorts = newValue.compactMap { (1...65_535).contains($0) ? UInt16($0) : nil } }
    }

    /// Bonjour-advertised server URL once registration completes, or nil.
    /// (Historical property name keeps the original "Sever" misspelling so the
    /// `PVWebServer.shared.bonjourSeverURL` call site in SourcesView still
    /// resolves.)
    @objc public var bonjourSeverURL: URL? { server.bonjourServerURL }

    /// Register a block invoked on a background queue for each completed upload path
    /// before the debounced library rescan runs (used for archive extraction).
    @objc public func setUploadPostProcessor(_ block: @escaping (String) -> Void) {
        uploadPostProcessor = block
    }

    /// Register a block returning custom snackbar text for a debounced upload burst.
    /// Return `nil` to use the default "Upload received" message.
    @objc public func setUploadSummaryProvider(_ block: @escaping (Int) -> String?) {
        uploadSummaryProvider = block
    }

    // MARK: - Async route registry

    /// Register an async route that owns its full HTTP response — status,
    /// headers, and either an in-memory body or a file streamed from disk at a
    /// byte offset.
    ///
    /// This is the seam features hang their own HTTP API off (continuity
    /// handoff, nearby library sharing) instead of editing the server's private
    /// route switch. Registration is independent of the listener's lifetime:
    /// routes registered while the server is stopped are live as soon as it
    /// starts, and survive the stop/start cycle
    /// `WebServerLifecycleService` drives.
    ///
    /// ⚠️  This server is **plain HTTP on the local network** — no TLS. Read the
    /// transport-security note at the top of `WebRoute.swift` before adding a
    /// route that serves anything a user would mind leaking on a shared Wi-Fi.
    /// Registers an async handler for every path below `pathPrefix`, for a route whose last
    /// segment is its subject (`GET /api/benchmarks/<name>`). An exact route at the same path
    /// wins, whatever the registration order. `handler` sees the full path and must validate
    /// that segment itself.
    public func addAsyncHandler(forMethod method: String, pathPrefix: String,
                                handler: @escaping WebRouteHandler) {
        server.addAsyncHandler(forMethod: method, pathPrefix: pathPrefix, handler: handler)
    }

    public func addAsyncHandler(forMethod method: String, path: String,
                                handler: @escaping WebRouteHandler) {
        server.addAsyncHandler(forMethod: method, path: path, handler: handler)
    }

    // MARK: - Import / rescan bridge

    @objc private func onUploadStarted(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uploadsInFlight += 1
            self.lastUploadActivity = Date()
        }
    }

    @objc private func onUploadCompleted(_ note: Notification) {
        let path = note.userInfo?["filePath"] as? String
        let processor = uploadPostProcessor
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uploadsInFlight = max(0, self.uploadsInFlight - 1)
            self.lastUploadActivity = Date()
        }

        if let path, let processor {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                processor(path)
                DispatchQueue.main.async {
                    self?.scheduleRescan()
                }
            }
            return
        }

        // NotificationCenter delivers on the poster's thread (the server's
        // background queue). Marshal all debounce state onto main so it isn't
        // raced against the work item, which reads/zeroes it on main.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRescan()
        }
    }

    private func scheduleRescan() {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingUploadCount += 1

        // Debounce: a multi-file drop fires one notification per file. Coalesce
        // a burst into a single rescan ~1.5s after the last file lands.
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.uploadsInFlight > 0 {
                if Date().timeIntervalSince(self.lastUploadActivity) < Self.uploadActivityStaleAfter {
                    // Something is still being written: check again shortly instead of
                    // indexing a partial file. `pendingUploadCount` keeps accumulating.
                    self.rearmRescan(after: Self.rescanRecheck)
                    return
                }
                NSLog("[PVWebServer] \(self.uploadsInFlight) upload(s) never completed; rescanning anyway")
                self.uploadsInFlight = 0
            }
            let count = self.pendingUploadCount
            self.pendingUploadCount = 0

            // Trigger the library rescan the same way an in-app import does.
            NotificationCenter.default.post(
                name: Notification.Name("DOLImportFileFinishedNotification"),
                object: self, userInfo: nil
            )

            // Surface a toast via iCube's snackbar channel.
            let defaultText = count == 1 ? "Upload received" : "\(count) uploads received"
            let text = self.uploadSummaryProvider?(count) ?? defaultText
            NotificationCenter.default.post(
                name: Notification.Name("DOLShowSnackbar"),
                object: nil, userInfo: ["text": text]
            )
        }
        rescanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rescanDebounce, execute: work)
    }

    private func rearmRescan(after delay: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let work = rescanWorkItem else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - WebRouteRegistering

/// `PVWebServer` is the app-wide route host. Features take this protocol
/// rather than the concrete singleton so their route registration is testable
/// against a collecting stub.
extension PVWebServer: WebRouteRegistering {}
