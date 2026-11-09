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
