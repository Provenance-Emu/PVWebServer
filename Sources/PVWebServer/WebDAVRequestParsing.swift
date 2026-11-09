//
//  WebDAVRequestParsing.swift
//  PVWebServer
//
//  Pure parsing and formatting for WebDAV bodies and properties. Lexical on purpose: clients
//  vary the namespace prefix, and a malformed body should still get a usable answer.
//

import Foundation

/// The DAV properties a PROPFIND asked for. Part of the listing cache key.
struct PropfindProperties: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let resourceType = Self(rawValue: 1 << 0)
    static let creationDate = Self(rawValue: 1 << 1)
    static let lastModified = Self(rawValue: 1 << 2)
    static let contentLength = Self(rawValue: 1 << 3)
    static let supportedLock = Self(rawValue: 1 << 4)
    static let quotaAvailable = Self(rawValue: 1 << 5)
    static let quotaUsed = Self(rawValue: 1 << 6)
    /// Microsoft extensions Finder asks for alongside the RFC 4331 quota properties.
    static let msQuota = Self(rawValue: 1 << 7)
    static let msQuotaUsed = Self(rawValue: 1 << 8)
    static let displayName = Self(rawValue: 1 << 9)
    static let contentType = Self(rawValue: 1 << 10)

    static let all: Self = [
        .resourceType, .creationDate, .lastModified, .contentLength, .supportedLock,
        .quotaAvailable, .quotaUsed, .msQuota, .msQuotaUsed, .displayName, .contentType
    ]

    var wantsQuota: Bool { !isDisjoint(with: [.quotaAvailable, .quotaUsed, .msQuota, .msQuotaUsed]) }
}

struct WebDAVVolumeQuota: Sendable {
    let available: Int64
    let used: Int64
    let total: Int64
}

enum WebDAVRequestParsing {
    private static let propertyNames: [(String, PropfindProperties)] = [
        ("resourcetype", .resourceType),
        ("creationdate", .creationDate),
        ("getlastmodified", .lastModified),
        ("getcontentlength", .contentLength),
        ("supportedlock", .supportedLock),
        ("quota-available-bytes", .quotaAvailable),
        ("quota-used-bytes", .quotaUsed),
        ("quotaused", .msQuotaUsed),
        ("displayname", .displayName),
        ("getcontenttype", .contentType)
    ]

    /// An empty body, `allprop`, or a body naming nothing we know means every property.
    static func propfindProperties(_ body: Data) -> PropfindProperties {
        guard !body.isEmpty, let xml = String(data: body, encoding: .utf8)?.lowercased(),
              !xml.contains("allprop") else { return .all }
        var properties: PropfindProperties = []
        for (name, property) in propertyNames where xml.contains(name) {
            properties.insert(property)
        }
        // Bare `quota` is a prefix of the others, so it needs its own whole-element match.
        if xml.range(of: "<([a-z0-9_-]+:)?quota[\\s/>]", options: .regularExpression) != nil {
            properties.insert(.msQuota)
        }
        return properties.isEmpty ? .all : properties
    }

    /// A LOCK with no body refreshes an existing lock, which needs no validation. Otherwise only
    /// the exclusive write locks we can pretend to honour are accepted.
    static func isSupportedLockRequest(_ body: Data) -> Bool {
        guard !body.isEmpty else { return true }
        guard let xml = String(data: body, encoding: .utf8)?.lowercased() else { return false }
        return xml.contains("lockscope") && xml.contains("exclusive")
            && xml.contains("locktype") && xml.contains("write")
    }

    private static let dateLock = NSLock()
    private static let lastModifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    /// `getlastmodified` is an RFC 1123 date (RFC 4918 §15.7). ISO 8601 belongs to `creationdate`.
    static func lastModifiedString(_ date: Date) -> String {
        dateLock.lock()
        defer { dateLock.unlock() }
        return lastModifiedFormatter.string(from: date)
    }
}
