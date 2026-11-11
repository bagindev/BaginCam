import os

/// Log app -> bisa dibaca dari Windows lewat:
///   python pc-lab\iphone_syslog.py --detik 60 --proses BaginCam
enum Log {
    static let camera = Logger(subsystem: "dev.bagincam.app", category: "camera")
    static let lut = Logger(subsystem: "dev.bagincam.app", category: "lut")
    static let hdr = Logger(subsystem: "dev.bagincam.app", category: "hdrplus")
    static let sr = Logger(subsystem: "dev.bagincam.app", category: "aizoom")
}
