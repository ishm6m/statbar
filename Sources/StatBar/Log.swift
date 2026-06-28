import Foundation
import os

/// Centralized OSLog loggers (PRD v1.0 §4). Replaces `print` everywhere.
///
/// Privacy: never log license keys or PII. String interpolation in OSLog is
/// `.private` by default for dynamic values on release builds, but we go
/// further — call sites only pass coarse, non-identifying values (sport names,
/// status codes, counts, booleans). License keys and team-specific data never
/// reach a logger.
enum Log {
    private static let subsystem = "com.getstatbar.StatBar"

    static let api = Logger(subsystem: subsystem, category: "api")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let updates = Logger(subsystem: subsystem, category: "updates")
    static let license = Logger(subsystem: subsystem, category: "license")
    static let analytics = Logger(subsystem: subsystem, category: "analytics")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
