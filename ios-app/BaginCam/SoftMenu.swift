import SwiftUI

/// v0.41.6: pengganti `Menu` SwiftUI (UIMenu iOS) untuk chip & ubin pilihan.
/// UIMenu memotret dan menyembunyikan sebagian isi di belakangnya selama terbuka, lalu menggambar ulang saat ditutup
/// (rekam layar 18 Nov 12:51: ubin laci "Garis bingkai", "Layar penuh", "AI Upscale", "LUT" hilang lalu muncul =
/// berkedip), dan tombolnya "berubah bentuk" menjadi menu (chip atas ikut redup / hilang). SoftMenu = popover kecil
/// biasa: isi di belakang tidak disentuh. Isi ditulis sama seperti `Menu` (Button + check, Text, Toggle, Section);
/// submenu ditulis `SoftSection("judul") { ... }` (baris yang bisa dibuka-tutup). Pilihan (Button) menutup panel.
struct SoftMenu<Content: View, Label: View>: View {
    private let content: () -> Content
    private let label: () -> Label
    @State private var open = false
    @State private var height: CGFloat = 120

    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: @escaping () -> Label) {
        self.content = content
        self.label = label
    }

    var body: some View {
        Button { open = true } label: { label() }
            .popover(isPresented: $open, arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content() }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: SoftMenuHeight.self, value: g.size.height)
                        })
                }
                .onPreferenceChange(SoftMenuHeight.self) { h in height = h }
                .frame(width: 300, height: min(max(height, 44), 470))
                .buttonStyle(SoftRowStyle())
                .labelStyle(SoftCheckLabelStyle())
                .toggleStyle(SoftToggleStyle())
                .font(.subheadline)
                .tint(.yellow)
                .environment(\.softMenuClose, { open = false })
                .environment(\.colorScheme, .dark)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Color(white: 0.13))
            }
    }
}

private struct SoftMenuHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SoftMenuCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var softMenuClose: (() -> Void)? {
        get { self[SoftMenuCloseKey.self] }
        set { self[SoftMenuCloseKey.self] = newValue }
    }
}

/// baris pilihan: lebar penuh, sorot saat ditekan, menutup panel setelah dipilih
struct SoftRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftRow(configuration: configuration)
    }

    private struct SoftRow: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.softMenuClose) private var close
        var body: some View {
            VStack(alignment: .leading, spacing: 2) { configuration.label }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(configuration.isPressed ? Color.white.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    let c = close
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { c?() }
                })
        }
    }
}

/// tanda centang di kanan (seperti menu iOS), judul di kiri
struct SoftCheckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.title
            Spacer(minLength: 8)
            configuration.icon.foregroundStyle(.yellow).font(.footnote.bold())
        }
    }
}

/// submenu di dalam SoftMenu: judul + chevron, isi tampil di bawahnya saat dibuka
struct SoftSection<Content: View>: View {
    private let title: String
    private let content: () -> Content
    @State private var expanded = false

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack {
                    Text(title).foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.5))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.leading, 10)
                    .background(Color.white.opacity(0.05))
            }
            Divider().overlay(Color.white.opacity(0.08))
        }
    }
}

/// saklar di dalam SoftMenu (jarak sama dengan baris pilihan)
struct SoftToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label.foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch).tint(.yellow)
        }
        .padding(.vertical, 6)
    }
}

/// kelompok berjudul di dalam SoftMenu (pengganti Section di menu)
struct SoftGroup<Content: View>: View {
    private let title: String
    private let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 10).padding(.bottom, 2)
            content()
            Divider().overlay(Color.white.opacity(0.08)).padding(.top, 4)
        }
    }
}
