import SwiftUI

/// Descubrir: recomendaciones de podcasts similares.
/// Pendiente de conectar un servicio externo (Listen Notes / Podchaser / Taddy).
struct DiscoverView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            Theme.background(store.backgroundStyle).ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "safari")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accentLight)
                Text("Descubrir")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("Aquí te recomendaremos podcasts parecidos a los que escuchas. Pendiente de elegir el servicio.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }
}
