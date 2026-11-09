//
//  WebServerLog.swift
//  PVWebServer
//
//  Where the server's log lines go. The default is NSLog, which an app with its own logger
//  replaces with `setHandler`.
//

import Foundation

public enum WebServerLogLevel: Sendable {
    case debug, info, warning, error
}

public enum WebServerLog {
    public typealias Handler = @Sendable (WebServerLogLevel, String) -> Void

    private static let lock = NSLock()
    private static var handler: Handler?

    /// Replaces where log lines go for every server in the process; nil restores NSLog. Called
    /// on the server's queues, per request at `.debug`, so keep it cheap.
    public static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    static func log(_ level: WebServerLogLevel, _ message: @autoclosure () -> String) {
        lock.lock()
        let handler = handler
        lock.unlock()
        if let handler {
            handler(level, message())
        } else {
            NSLog("%@", "[ROMUploadServer] \(message())")
        }
    }
}
