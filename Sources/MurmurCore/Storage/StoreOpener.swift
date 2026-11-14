import Foundation
import GRDB

/// Opens the on-disk store, retrying a transient failure (a second process still closing the
/// file) before giving up. A file that is not a database fails at once. It never moves, rewrites or deletes the database file.
public enum StoreOpener {
    public static func open(
        url: URL, attempts: Int = 3, retryDelay: TimeInterval = 0.5,
        using open: (URL) throws -> Store = { try Store(url: $0) }
    ) throws -> Store {
        var lastError: (any Error)?
        for attempt in 1...max(1, attempts) {
            do {
                return try open(url)
            } catch {
                lastError = error
                if isNotADatabase(error) { throw error }
                if attempt < attempts, retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
            }
        }
        throw lastError ?? CocoaError(.fileReadUnknown)
    }

    /// A file that is not a database will not become one by waiting, so retrying only delays the alert.
    private static func isNotADatabase(_ error: any Error) -> Bool {
        (error as? DatabaseError)?.resultCode == .SQLITE_NOTADB
    }
}
