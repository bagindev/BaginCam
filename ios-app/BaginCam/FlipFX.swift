import SwiftUI
import UIKit

/// v0.41.3: efek di sekitar Dynamic Island saat ganti kamera depan / belakang.
/// Dynamic Island asli tidak bisa dianimasikan app yang sedang terbuka (Live Activity tidak tampil di pulau selama
/// app-nya di depan), jadi efek digambar app sendiri tepat di posisi pulau: bentuk hitam menyatu dengan pulau,
/// cincin / cahaya mengelilinginya. Posisi pulau diperkirakan dari tepi aman atas layar (16 Pro / Pro Max: 14 pt
/// dari atas, 15 Pro / 14 Pro: 11 pt; lebar 126 pt, tinggi 37,33 pt; lensa depan di ujung kanan pulau).
enum FlipFX: String, CaseIterable, Identifiable {
    case off = "Mati"
    case island = "Pulau"
    case ring = "Cincin"
    case pulse = "Denyut"
    case ringIsland = "Cincin + pulau"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .off: return "Mati"
        case .island: return "Pulau melebar (ala Dynamic Island)"
        case .ring: return "Cincin di lensa (ala Pixel)"
        case .pulse: return "Denyut cahaya"
        case .ringIsland: return "Cincin + pulau melebar"
        }
    }
}

struct FlipFXOverlay: View {
    let trigger: Int
    let toFront: Bool
    let style: FlipFX
    @State private var start: Date?
    @State private var front = true
    @State private var shownStyle: FlipFX = .off

    private static let duration = 1.25

    var body: some View {
        GeometryReader { g in
            if let start {
                TimelineView(.animation) { tl in
                    let e = tl.date.timeIntervalSince(start)
                    let isl = Self.islandRect(width: g.size.width)
                    ZStack(alignment: .topLeading) {
                        switch shownStyle {
                        case .island: islandFX(e, isl)
                        case .ring: ringFX(e, isl)
                        case .pulse: pulseFX(e, isl)
                        case .ringIsland:
                            islandFX(e, isl)
                            ringFX(e, isl)
                        case .off: EmptyView()
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            guard style != .off else { return }
            let d = Date()
            front = toFront
            shownStyle = style
            start = d
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.05) { if start == d { start = nil } }
        }
    }

    // MARK: posisi pulau

    static func islandRect(width: CGFloat) -> CGRect {
        let top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 59
        // tanpa Dynamic Island (poni / layar biasa): efek di tengah atas layar
        let y: CGFloat = top >= 61 ? 14 : (top >= 51 ? 11 : 6)
        return CGRect(x: (width - 126) / 2, y: y, width: 126, height: 37.33)
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    /// ease-out pegas ringan (sedikit lewat lalu kembali)
    private static func spring(_ x: Double) -> Double {
        let t = clamp(x)
        return 1 - pow(1 - t, 3) + sin(t * .pi) * 0.08
    }
    private static func easeInOut(_ x: Double) -> Double {
        let t = clamp(x)
        return t * t * (3 - 2 * t)
    }

    // MARK: pulau melebar - ikon kiri, tulisan kanan (seperti aktivitas di Dynamic Island)

    @ViewBuilder private func islandFX(_ e: Double, _ isl: CGRect) -> some View {
        let open = e < 0.85 ? Self.spring(e / 0.38) : 1 - Self.easeInOut((e - 0.85) / 0.35)
        let w = isl.width + (268 - isl.width) * open
        let h = isl.height + (46 - isl.height) * open
        let content = Self.clamp((open - 0.55) / 0.35)
        ZStack {
            Capsule().fill(Color.black)
            HStack(spacing: 0) {
                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: (w - isl.width) / 2 + 6)
                Spacer(minLength: isl.width - 12)
                Text(front ? "Depan" : "Belakang")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: (w - isl.width) / 2 + 6)
            }
            .opacity(content)
        }
        .frame(width: max(w, isl.width), height: max(h, isl.height))
        .position(x: isl.midX, y: isl.minY + max(h, isl.height) / 2)
    }

    // MARK: cincin di lensa depan (ala Pixel)

    @ViewBuilder private func ringFX(_ e: Double, _ isl: CGRect) -> some View {
        let c = CGPoint(x: isl.maxX - isl.height / 2, y: isl.midY)
        if front {
            // cincin digambar memutar mengelilingi lensa, lalu melebar & memudar
            let draw = Self.easeInOut(e / 0.55)
            let grow = Self.easeInOut((e - 0.55) / 0.6)
            let r = 23 + 14 * grow
            ZStack {
                Circle()
                    .trim(from: 0, to: draw)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90 + 200 * draw))
                    .frame(width: r * 2, height: r * 2)
                    .shadow(color: .white.opacity(0.8), radius: 4)
                Circle()
                    .stroke(Color.yellow.opacity(0.7), lineWidth: 1.5)
                    .frame(width: (r + 8) * 2, height: (r + 8) * 2)
                    .opacity(draw * (1 - grow) * 0.8)
            }
            .opacity(1 - grow)
            .position(c)
        } else {
            // ke belakang: cincin penuh melebar keluar dan hilang
            let t = Self.easeInOut(e / 0.9)
            Circle()
                .stroke(Color.white, lineWidth: 3 * (1 - t) + 0.5)
                .frame(width: (20 + 50 * t) * 2, height: (20 + 50 * t) * 2)
                .opacity(1 - t)
                .shadow(color: .white.opacity(0.6), radius: 4)
                .position(c)
        }
    }

    // MARK: denyut cahaya di tepi pulau

    @ViewBuilder private func pulseFX(_ e: Double, _ isl: CGRect) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let t = Self.clamp((e - Double(i) * 0.22) / 0.8)
                let g = 26 * Self.easeInOut(t)
                Capsule()
                    .stroke(front ? Color.yellow : Color.white, lineWidth: 2.5)
                    .frame(width: isl.width + g * 2, height: isl.height + g * 1.2)
                    .shadow(color: (front ? Color.yellow : Color.white).opacity(0.8), radius: 6)
                    .opacity(t > 0 ? (1 - t) * 0.9 : 0)
            }
        }
        .position(x: isl.midX, y: isl.midY)
    }
}
