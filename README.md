# PVWebServer

Pure-Swift HTTP/WebDAV upload server using Network.framework. Includes the route
registry consumed by PVContinuity, streaming uploads, a file browser, and the
PVWebServer facade. Extracted with history from iCube Source/iOS/PVWebServer.

The facade derives its page and Bonjour names from the host application bundle.
The host supplies the served directory and registers any application routes.

Run `swift test` for the server policy, route and filesystem tests.

## Consumer migration

This package preserves iCube’s API. Provenance currently has a different package
also named PVWebServer, with ObjC/GCDWebServer and Hummingbird products. Do not
replace that dependency without porting its callers first. A graph cannot contain
both packages under the same identity.

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
