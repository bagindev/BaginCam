import AVFoundation
import Foundation
import os

/// v0.34: kemampuan HP, dibaca sekali. Dipakai untuk membatasi fitur di iPhone selain 16 Pro Max
/// (RAM kecil, tanpa tele, tanpa sensor 48MP) dan dicatat di log supaya log penguji bisa dibaca.
enum DeviceCaps {
    static let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    static let cores = ProcessInfo.processInfo.activeProcessorCount

    struct LensInfo {
        let name: String
        let maxLong: Int        // sisi panjang foto terbesar (piksel)
    }

    /// lensa belakang yang ada + resolusi foto terbesarnya
    static let backLenses: [LensInfo] = {
        let types: [(AVCaptureDevice.DeviceType, String)] = [
            (.builtInUltraWideCamera, "Ultra Wide"), (.builtInWideAngleCamera, "Utama"), (.builtInTelephotoCamera, "Tele")]
        return types.compactMap { type, name in
            guard let d = AVCaptureDevice.default(type, for: .video, position: .back) else { return nil }
            let long = d.formats.flatMap { $0.supportedMaxPhotoDimensions }.map { Int(max($0.width, $0.height)) }.max() ?? 0
            return LensInfo(name: name, maxLong: long)
        }
    }()

    static let has48MP = backLenses.contains { $0.maxLong >= 8000 }
    static let hasTele = backLenses.contains { $0.name == "Tele" }
    static let hasUltraWide = backLenses.contains { $0.name == "Ultra Wide" }
    static let multiCam = AVCaptureMultiCamSession.isMultiCamSupported

    /// sisa memori (MB) sebelum iOS menutup app; 0 = tidak diketahui
    static var availableMB: Int { Int(os_proc_available_memory() / 1_048_576) }

    /// Cadangan untuk menggabung frame, develop RAW, AI dan gambar hasil. Perkiraan awal - dikalibrasi dari
    /// baris log "Memori:" (sisa sebelum burst / setelah capture / setelah proses).
    private static let reserveBytes = 700 * 1_048_576

    /// Jumlah frame burst RAW yang muat di memori. `frameBytes` = ukuran satu frame Bayer di memori.
    /// Sisa memori dibaca dari iOS saat itu juga; bila tidak diketahui dipakai 40 % RAM.
    static func frameLimit(wanted: Int, frameBytes: Int) -> (frames: Int, roomMB: Int) {
        let avail = Int(os_proc_available_memory())
        let room = avail > 0 ? avail : Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.4)
        let fit = (room - reserveBytes) / max(frameBytes, 1)
        return (min(wanted, max(4, fit)), room / 1_048_576)
    }

    static var summary: String {
        let lenses = backLenses.map { "\($0.name) \($0.maxLong)" }.joined(separator: " / ")
        return String(format: "RAM %.1f GB, %d inti, lensa belakang %@, 48MP %@, tele %@, multi-kamera %@, sisa memori %d MB",
                      ramGB, cores, lenses.isEmpty ? "-" : lenses, has48MP ? "ya" : "tidak", hasTele ? "ya" : "tidak",
                      multiCam ? "ya" : "tidak", availableMB)
    }
}
