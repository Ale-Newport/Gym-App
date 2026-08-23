import Foundation
import OSLog

/// Categorised loggers. Everything technical goes through `Logger`, which stays out of release
/// builds' stdout and never records personal data.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.gymapp.forge"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let catalog = Logger(subsystem: subsystem, category: "catalog")
    static let training = Logger(subsystem: subsystem, category: "training")
    static let nutrition = Logger(subsystem: subsystem, category: "nutrition")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let health = Logger(subsystem: subsystem, category: "health")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let export = Logger(subsystem: subsystem, category: "export")
}
