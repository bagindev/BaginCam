import os

/// Log app -> bisa dibaca dari Windows lewat:
///   python pc-lab\iphone_syslog.py --detik 60 --proses BaginCam
/// v0.38.1: pakai .notice (disimpan ke disk). .info hanya di memori dan bisa hilang dari file log saat HP sibuk.
enum Log {
    static let camera = Logger(subsystem: "dev.bagincam.app", category: "camera")
    static let lut = Logger(subsystem: "dev.bagincam.app", category: "lut")
    static let hdr = Logger(subsystem: "dev.bagincam.app", category: "hdrplus")
    static let sr = Logger(subsystem: "dev.bagincam.app", category: "aizoom")
}
