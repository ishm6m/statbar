import Foundation
import os

/// Centralized OSLog loggers. Replaces `print` everywhere.
///
/// Privacy: never log PII. String interpolation in OSLog is
/// `.private` by default for dynamic values on release builds, but we go
/// further — call sites only pass coarse, non-identifying values (sport names,
/// status codes, counts, booleans). Team-specific data never reaches a logger.
enum Log {
    private static let subsystem = "com.getstatbar.StatBar"

    static let api = Logger(subsystem: subsystem, category: "api")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let updates = Logger(subsystem: subsystem, category: "updates")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
