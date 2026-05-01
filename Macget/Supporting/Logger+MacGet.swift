import Foundation
import OSLog

/// Centralized `os.Logger` subsystems. Use these instead of `print` so logs are
/// queryable in Console.app and `log show --predicate 'subsystem == "com.macget"'`.
enum Log {
    static let subsystem = "com.macget"

    static let app    = Logger(subsystem: subsystem, category: "App")
    static let engine = Logger(subsystem: subsystem, category: "Engine")
    static let ui     = Logger(subsystem: subsystem, category: "UI")
    static let net    = Logger(subsystem: subsystem, category: "Net")
}
