import SwiftUI

/// Contenedor principal con las cuatro pestañas de Unicast.
struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        TabView(selection: $store.selectedTab) {
            LibraryView()
                .tabItem { Label("Biblioteca", systemImage: "square.stack") }
                .tag(0)
            PlaylistsView()
                .tabItem { Label("Listas", systemImage: "list.bullet") }
                .tag(1)
            DiscoverView()
                .tabItem { Label("Descubrir", systemImage: "safari") }
                .tag(2)
            SearchView()
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
                .tag(3)
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: $store.isPlayerPresented) {
            PlayerView()
        }
        .onAppear {
            // Para poder capturar pantallas de otras pestañas en el simulador.
            switch ProcessInfo.processInfo.environment["UNICAST_PREVIEW"] {
            case "playlistDetail", "createPlaylist", "createSmart": store.selectedTab = 1
            case "search", "addPodcast": store.selectedTab = 3
            default: break
            }
        }
    }
}
