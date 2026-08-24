import Foundation
import OSLog

/// Central OSLog loggers. Only used OUTSIDE real-time audio callbacks.
/// Audio sample content is never logged.
public enum AppLog {
    public static let subsystem = "com.bnewable.DisplayVolume"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let devices = Logger(subsystem: subsystem, category: "devices")
    public static let keys = Logger(subsystem: subsystem, category: "mediakeys")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
