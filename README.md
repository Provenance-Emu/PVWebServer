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

### Upload outcomes and replacement

Set `WebServerConfiguration.onUploadResult` to receive a terminal result for
each accepted PUT target or multipart file part. It contains a transfer ID,
destination, bytes written, and an outcome. Only `.completed` means a file
was published. A Finder metadata upload can finish as `.discardedMetadata`.
Requests rejected before a file transfer, such as an invalid path, do not
produce a result. The byte observer and existing notifications remain available.

The server stages uploads in the destination directory and atomically renames
them after a complete body and a successful close. A failed replacement
leaves the original file intact. Multipart requests commit each complete file
part separately. A later failed part does not roll back earlier files.

## Transfer benchmark

Use the same script against either server version. Pass its URL or the exact
Bonjour instance name.

```sh
Scripts/webserver_transfer_bench.sh --url http://127.0.0.1:8080/ --sizes 256k,8m,64m --runs 5 --download
Scripts/webserver_transfer_bench.sh --service "iFly EMU" --runs 5 --replace --download --json
```

The script compares WebDAV PUT, browser PUT, and multipart POST, with optional
browser GET. `--replace` seeds each destination before timing replacements.
Use an isolated test library because the server can import uploads. Each run
uses its own folder and removes it at exit unless `--no-cleanup` is passed.
Keep the device, network, payloads, and gameplay state the same for comparisons.
The reported rate is wire Mbps, including multipart framing for POST.

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
