import os

/// Log app -> bisa dibaca dari Windows lewat:
///   python pc-lab\iphone_syslog.py --detik 60 --proses ModKamera
enum Log {
    static let camera = Logger(subsystem: "dev.modkamera.app", category: "camera")
    static let lut = Logger(subsystem: "dev.modkamera.app", category: "lut")
}
