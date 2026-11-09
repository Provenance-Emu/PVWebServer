# PVWebServer

Pure-Swift HTTP/WebDAV upload server using Network.framework. Includes the route
registry consumed by PVContinuity, streaming uploads, a file browser, and the
PVWebServer facade. Extracted with history from iCube Source/iOS/PVWebServer.

The facade derives its page and Bonjour names from the host application bundle.
The host supplies the served directory and registers any application routes.

Run `swift test` for the server policy, route and filesystem tests.

## Using it from an app

`PVWebServer.shared` is iCube's server: it serves iCube's library folder and asks
for a library rescan after each upload. Any other app creates its own:

```swift
let server = PVWebServer(configuration: WebServerConfiguration(
    rootDirectory: documents,
    defaultUploadDirectory: documents.appendingPathComponent("Imports"),
    pageTitle: "Provenance",
    preferredPorts: [8080, 8180, 8181],
    reportsWebDAVMovesAsUploads: false
))
server.setUnexpectedStopHandler { /* iOS closed the socket; start again */ }
try await server.start()
```

HTTP and WebDAV share one port. Routes added with `addAsyncHandler` run before the
built-in ones, so `GET /` can replace the upload page. They match exact paths, so
a route takes its subject from the query string; check it with
`WebServerPathSafety.resolve`. Bodies are `.data`, `.file` (read from disk at an
offset) or `.stream` (open-ended, such as Server-Sent Events).

To follow what clients do, observe `PVWebServerFileUploadCompletedNotificationName`,
`PVWebServerFileDeletedNotificationName`, `PVWebServerFileMovedNotificationName` and
`PVWebServerFolderCreatedNotificationName`. They fire for the browser page and for
WebDAV alike.

### Fitting the server to an app

More options on `WebServerConfiguration`, all off or unchanged by default:

- `uploadPageRenderer` draws `GET /` from the app's own templates and keeps the
  folder listing the server builds.
- `uploadTransferObserver` sees the bytes of each upload reaching disk.
- `preservesMultipartSubfolders` keeps the sender's folder path in a browser upload.
  Games that need their CHDs in a set folder rely on this.
- `advertisesWebDAVService` turns off the `_webdav._tcp` record when the app publishes
  its own. `setBonjourRegistrationHandler(_:)` reports the name mDNS really registered.

`addAsyncHandler(forMethod:pathPrefix:handler:)` matches every path below a prefix,
for routes whose last segment is their subject. Exact routes win.
`WebServerLog.setHandler(_:)` sends the log lines to the app's logger, and
`seedCachedIPAddress(_:)` saves the first `ipAddress` a walk of the interfaces.

Routes see `//api/x` as `/api/x`: iOS and tvOS 18 NSURL produce that path when joining
onto a base URL ending in a slash. Routes run for WebDAV clients too, so an app can
put access control in a route. The WebDAV file layer itself allows anonymous access.

The original GPL-2.0-or-later source notices are retained; see COPYING.

## Precompiled XCFramework

Version tags trigger the release workflow. The GitHub Release includes
`PVWebServer.xcframework.zip` and its SwiftPM checksum. The dynamic framework
contains the Swift module and web templates for iOS, tvOS, watchOS, visionOS
(devices and simulators), macOS, and Mac Catalyst.

For direct Xcode integration, unzip the XCFramework and add it to the app
target with **Embed & Sign**. Import the module as `PVWebServer`. To build
assets for an existing tag, run **Release XCFramework** from the Actions tab
and enter the tag.

The first all-platform binary release must use a tag that includes the
watchOS build fix. The 1.1.0 source tag predates that fix.
