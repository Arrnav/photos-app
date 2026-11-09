import OSLog

/// OSLog categories used across the app. Filter in Console.app with
/// `subsystem:com.ethwood.photos category:<name>`.
public enum Log {
    public static let subsystem = "com.ethwood.photos"

    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let backup = Logger(subsystem: subsystem, category: "backup")
    public static let networking = Logger(subsystem: subsystem, category: "networking")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let media = Logger(subsystem: subsystem, category: "media")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
