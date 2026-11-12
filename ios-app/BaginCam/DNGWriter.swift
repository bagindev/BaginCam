import Foundation

/// Tulis ulang DNG Bayer Apple dengan data CFA baru (tanpa kompresi).
///
/// Kenapa: `AVCapturePhotoFileDataRepresentationCustomizer.replacementRawPixelBuffer` ternyata
/// DIABAIKAN untuk Bayer RAW (v0.4.0: DNG HDR+ identik byte-per-byte dengan frame referensi).
/// Solusi: parse DNG asli (TIFF), salin SEMUA metadata (warna, lensa, opcode lens shading,
/// NoiseProfile, EXIF, MakerNote, GPS), ganti hanya struktur & data gambar.
/// Byte order file asli dipertahankan (DNG Apple = big-endian "MM").
enum DNGWriter {

    enum DNGError: Error, CustomStringConvertible {
        case parse(String)
        var description: String { if case .parse(let s) = self { return "DNG parse: \(s)" }; return "DNG" }
    }

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        var data: Data          // byte nilai mentah, byte order file
    }

    final class IFD {
        var entries: [UInt16: Entry] = [:]
        var exif: IFD?
        var gps: IFD?
        var subIFDs: [IFD] = []
    }

    private static let typeSize: [UInt16: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4,
                                                  10: 8, 11: 4, 12: 8, 13: 4]

    // tag struktur gambar - tidak disalin, dibuat ulang
    private static let structural: Set<UInt16> = [254, 256, 257, 258, 259, 262, 273, 277, 278, 279, 284,
                                                  322, 323, 324, 325, 330, 347, 513, 514,
                                                  50712,          // LinearizationTable (data kita sudah linear)
                                                  34665, 34853,   // pointer EXIF / GPS (dibuat ulang)
                                                  305]            // Software (diganti)

    // MARK: baca
    private struct Reader {
        let d: [UInt8]
        let big: Bool
        func u16(_ o: Int) throws -> UInt16 {
            guard o >= 0, o + 2 <= d.count else { throw DNGError.parse("u16 @\(o)") }
            return big ? UInt16(d[o]) << 8 | UInt16(d[o + 1]) : UInt16(d[o + 1]) << 8 | UInt16(d[o])
        }
        func u32(_ o: Int) throws -> UInt32 {
            guard o >= 0, o + 4 <= d.count else { throw DNGError.parse("u32 @\(o)") }
            if big { return UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3]) }
            return UInt32(d[o + 3]) << 24 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 1]) << 8 | UInt32(d[o])
        }
    }

    private static func parseIFD(_ r: Reader, at off: Int, depth: Int = 0) throws -> IFD {
        guard depth < 4 else { throw DNGError.parse("IFD terlalu dalam") }
        let ifd = IFD()
        let n = Int(try r.u16(off))
        for i in 0..<n {
            let e = off + 2 + i * 12
            let tag = try r.u16(e), type = try r.u16(e + 2), count = try r.u32(e + 4)
            let size = (typeSize[type] ?? 1) * Int(count)
            let valOff = size <= 4 ? e + 8 : Int(try r.u32(e + 8))
            guard valOff >= 0, valOff + size <= r.d.count else { continue }
            ifd.entries[tag] = Entry(tag: tag, type: type, count: count, data: Data(r.d[valOff..<(valOff + size)]))
            switch tag {
            case 34665: ifd.exif = try? parseIFD(r, at: Int(try r.u32(e + 8)), depth: depth + 1)
            case 34853: ifd.gps = try? parseIFD(r, at: Int(try r.u32(e + 8)), depth: depth + 1)
            case 330:
                for k in 0..<Int(count) {
                    let p = Int(try r.u32(valOff + k * 4))
                    if let sub = try? parseIFD(r, at: p, depth: depth + 1) { ifd.subIFDs.append(sub) }
                }
            default: break
            }
        }
        return ifd
    }

    private static func firstValue(_ e: Entry?, big: Bool) -> UInt32? {
        guard let e, !e.data.isEmpty else { return nil }
        let b = [UInt8](e.data)
        switch e.type {
        case 3, 8: return b.count >= 2 ? (big ? UInt32(b[0]) << 8 | UInt32(b[1]) : UInt32(b[1]) << 8 | UInt32(b[0])) : nil
        case 4, 9, 13:
            guard b.count >= 4 else { return nil }
            return big ? UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
                       : UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])
        default: return UInt32(b[0])
        }
    }

    // MARK: tulis
    private struct Out {
        var bytes: [UInt8] = []
        let big: Bool
        mutating func u16(_ v: UInt16) { bytes += big ? [UInt8(v >> 8), UInt8(v & 0xff)] : [UInt8(v & 0xff), UInt8(v >> 8)] }
        mutating func u32(_ v: UInt32) {
            bytes += big ? [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
                         : [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]
        }
        mutating func pad() { if bytes.count % 2 == 1 { bytes.append(0) } }
    }

    private static func numeric(_ tag: UInt16, short: UInt16? = nil, long: UInt32? = nil, big: Bool) -> Entry {
        var o = Out(big: big)
        if let short { o.u16(short); return Entry(tag: tag, type: 3, count: 1, data: Data(o.bytes)) }
        o.u32(long ?? 0)
        return Entry(tag: tag, type: 4, count: 1, data: Data(o.bytes))
    }

    private static func ascii(_ tag: UInt16, _ s: String) -> Entry {
        var b = Array(s.utf8); b.append(0)
        return Entry(tag: tag, type: 2, count: UInt32(b.count), data: Data(b))
    }

    /// Ukuran blok IFD (entri + area nilai) bila ditulis.
    private static func blockSize(_ entries: [Entry]) -> Int {
        var s = 2 + entries.count * 12 + 4
        for e in entries where e.data.count > 4 { s += e.data.count + (e.data.count % 2) }
        return s
    }

    /// Serialisasi IFD di posisi absolut `base`.
    private static func writeIFD(_ entries: [Entry], base: Int, into o: inout Out) {
        let sorted = entries.sorted { $0.tag < $1.tag }
        var valPos = base + 2 + sorted.count * 12 + 4
        var values: [UInt8] = []
        o.u16(UInt16(sorted.count))
        for e in sorted {
            o.u16(e.tag); o.u16(e.type); o.u32(e.count)
            if e.data.count <= 4 {
                var v = [UInt8](e.data)
                while v.count < 4 { v.append(0) }
                o.bytes += v
            } else {
                o.u32(UInt32(valPos))
                values += [UInt8](e.data)
                if e.data.count % 2 == 1 { values.append(0) }
                valPos += e.data.count + (e.data.count % 2)
            }
        }
        o.u32(0)            // tidak ada IFD berikutnya
        o.bytes += values
    }

    /// Buat DNG baru: metadata dari `original` + data CFA `pixels` (uint16 host order, w x h, tanpa padding).
    static func rewrite(original: Data, pixels: UnsafePointer<UInt16>, width: Int, height: Int,
                        software: String) throws -> Data {
        let src = [UInt8](original)
        guard src.count > 8 else { throw DNGError.parse("file terlalu kecil") }
        let big: Bool
        if src[0] == 0x4D && src[1] == 0x4D { big = true }
        else if src[0] == 0x49 && src[1] == 0x49 { big = false }
        else { throw DNGError.parse("bukan TIFF") }
        let r = Reader(d: src, big: big)
        let ifd0 = try parseIFD(r, at: Int(try r.u32(4)))

        // IFD gambar RAW utama: NewSubfileType 0 + CFA (32803)
        let candidates = [ifd0] + ifd0.subIFDs
        guard let raw = candidates.first(where: {
            (firstValue($0.entries[254], big: big) ?? 0) == 0 && firstValue($0.entries[262], big: big) == 32803
        }) else { throw DNGError.parse("IFD CFA tidak ditemukan") }
        if let rw = firstValue(raw.entries[256], big: big), let rh = firstValue(raw.entries[257], big: big),
           Int(rw) != width || Int(rh) != height {
            Log.hdr.error("Ukuran DNG \(rw, privacy: .public)x\(rh, privacy: .public) != buffer \(width, privacy: .public)x\(height, privacy: .public)")
        }

        // gabung metadata: IFD0 lalu ditimpa tag dari IFD RAW
        var merged: [UInt16: Entry] = [:]
        for (t, e) in ifd0.entries where !structural.contains(t) { merged[t] = e }
        if raw !== ifd0 { for (t, e) in raw.entries where !structural.contains(t) { merged[t] = e } }
        let pixelBytes = width * height * 2
        for e in [numeric(254, long: 0, big: big),
                  numeric(256, long: UInt32(width), big: big), numeric(257, long: UInt32(height), big: big),
                  numeric(258, short: 16, big: big), numeric(259, short: 1, big: big),
                  numeric(262, short: 32803, big: big), numeric(277, short: 1, big: big),
                  numeric(278, long: UInt32(height), big: big), numeric(279, long: UInt32(pixelBytes), big: big),
                  numeric(284, short: 1, big: big), ascii(305, software)] {
            merged[e.tag] = e
        }
        // EXIF tanpa pointer Interoperability IFD (40965) - offsetnya milik file lama
        let exifEntries = ifd0.exif.map { $0.entries.values.filter { $0.tag != 40965 } }
        let gpsEntries = ifd0.gps.map { Array($0.entries.values) }
        if exifEntries != nil { merged[34665] = numeric(34665, long: 0, big: big) }
        if gpsEntries != nil { merged[34853] = numeric(34853, long: 0, big: big) }
        merged[273] = numeric(273, long: 0, big: big)

        // tata letak: header | IFD0 | EXIF | GPS | data piksel
        let ifd0Base = 8
        var pos = ifd0Base + blockSize(Array(merged.values))
        let exifBase = pos
        if let ex = exifEntries { pos += blockSize(ex) }
        let gpsBase = pos
        if let gp = gpsEntries { pos += blockSize(gp) }
        pos += pos % 4 == 0 ? 0 : 4 - pos % 4
        let stripBase = pos

        if exifEntries != nil { merged[34665] = numeric(34665, long: UInt32(exifBase), big: big) }
        if gpsEntries != nil { merged[34853] = numeric(34853, long: UInt32(gpsBase), big: big) }
        merged[273] = numeric(273, long: UInt32(stripBase), big: big)

        var o = Out(big: big)
        o.bytes.reserveCapacity(stripBase + pixelBytes)
        o.bytes += big ? [0x4D, 0x4D, 0x00, 0x2A] : [0x49, 0x49, 0x2A, 0x00]
        o.u32(UInt32(ifd0Base))
        writeIFD(Array(merged.values), base: ifd0Base, into: &o)
        if let ex = exifEntries { writeIFD(ex, base: exifBase, into: &o) }
        if let gp = gpsEntries { writeIFD(gp, base: gpsBase, into: &o) }
        while o.bytes.count < stripBase { o.bytes.append(0) }
        guard o.bytes.count == stripBase else { throw DNGError.parse("offset tidak konsisten") }

        var data = Data(o.bytes)
        data.count = stripBase + pixelBytes
        data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            let dst = (base + stripBase).bindMemory(to: UInt16.self, capacity: width * height)
            for i in 0..<(width * height) { dst[i] = big ? pixels[i].bigEndian : pixels[i].littleEndian }
        }
        return data
    }
}
