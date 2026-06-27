import SwiftUI

/// Selector del degradado de fondo: estilos predefinidos o colores personalizados.
/// Le da vida al fondo sin dejar de ser elegante (idea del usuario).
struct BackgroundPickerView: View {
    @Environment(AppStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 9)]

    var body: some View {
        @Bindable var store = store

        ZStack {
            Theme.background(store.backgroundStyle).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(gradient(store.backgroundStyle))
                        .frame(height: 90)
                        .overlay(alignment: .bottomLeading) {
                            Text("unicast")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white).padding(11)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.surfaceBorder))
                    Text("Así se verá el fondo de la app")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)

                    Text("Estilos").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(BackgroundStyle.allCases) { style in
                            Button { store.backgroundStyle = style } label: { stylePreview(style) }
                                .buttonStyle(.plain)
                        }
                    }

                    Text("Personalizar")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.top, 6)
                    customRow("Color de arriba", color: store.backgroundStyle.top)
                    customRow("Color de abajo", color: store.backgroundStyle.bottom)
                }
                .padding(16)
            }
        }
        .navigationTitle("Fondo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func gradient(_ style: BackgroundStyle) -> LinearGradient {
        LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom)
    }

    private func stylePreview(_ style: BackgroundStyle) -> some View {
        let selected = style == store.backgroundStyle
        return VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(gradient(style))
                .frame(height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Theme.accent : Theme.surfaceBorder, lineWidth: selected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white).padding(5)
                    }
                }
            Text(style.displayName)
                .font(.system(size: 11))
                .foregroundStyle(selected ? .white : Theme.textSecondary)
        }
    }

    private func customRow(_ title: String, color: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(.white)
            Spacer()
            Circle().fill(color).frame(width: 22, height: 22)
                .overlay(Circle().stroke(Theme.surfaceBorder))
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 11).padding(.horizontal, 13)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
