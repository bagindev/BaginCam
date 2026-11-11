import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// LUT 3D format .cube (Adobe/Resolve). Urutan data: R paling cepat berubah,
/// sama dengan urutan yang diharapkan CIColorCube.
struct CubeLUT {
    enum CubeError: Error { case invalid(String) }

    let name: String
    let size: Int
    let data: Data   // RGBA Float32

    static func load(url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var values: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE")
                || line.hasPrefix("DOMAIN_") || line.hasPrefix("LUT_1D") {
                continue
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0
                values.reserveCapacity(size * size * size * 4)
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else { continue }
            values.append(r); values.append(g); values.append(b); values.append(1)
        }
        guard size > 1, values.count == size * size * size * 4 else {
            throw CubeError.invalid("ukuran \(size), \(values.count / 4) titik")
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(name: url.deletingPathExtension().lastPathComponent, size: size, data: data)
    }

    /// Filter Core Image. Input dikonversi ke sRGB (gamma) sebelum lookup, sesuai LUT Rec.709.
    func makeFilter() -> CIFilter {
        let f = CIFilter.colorCubeWithColorSpace()
        f.cubeDimension = Float(size)
        f.cubeData = data
        if let cs = CGColorSpace(name: CGColorSpace.sRGB) { f.colorSpace = cs }
        return f
    }
}

/// Daftar LUT: bawaan app (folder LUTs di bundle) + hasil import (Documents/LUTs).
final class LUTLibrary: ObservableObject {
    struct Item: Identifiable, Hashable {
        let url: URL
        var id: String { url.path }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    @Published var selected: Item?
    @Published private(set) var filter: CIFilter?

    static var importDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { reload() }

    func reload() {
        var urls: [URL] = []
        if let bundled = Bundle.main.url(forResource: "LUTs", withExtension: nil),
           let files = try? FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) {
            urls += files
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.importDir, includingPropertiesForKeys: nil) {
            urls += files
        }
        items = urls.filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Item.init(url:))
        Log.lut.info("LUT tersedia: \(self.items.count, privacy: .public)")
    }

    func select(_ item: Item?) {
        selected = item
        guard let item else { filter = nil; return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let lut = try CubeLUT.load(url: item.url)
                let f = lut.makeFilter()
                DispatchQueue.main.async {
                    if self.selected == item { self.filter = f }
                }
                Log.lut.info("LUT dimuat: \(lut.name, privacy: .public) size \(lut.size, privacy: .public)")
            } catch {
                Log.lut.error("Gagal muat LUT \(item.name, privacy: .public): \(String(describing: error), privacy: .public)")
                DispatchQueue.main.async { self.filter = nil }
            }
        }
    }

    /// Salin file .cube yang dipilih dari Files app ke Documents/LUTs.
    func importLUT(from url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dest = Self.importDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            reload()
            select(items.first { $0.url.lastPathComponent == dest.lastPathComponent })
        } catch {
            Log.lut.error("Import LUT gagal: \(String(describing: error), privacy: .public)")
        }
    }
}
