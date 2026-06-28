import SwiftUI

/// Pantalla de inicio (Biblioteca): saludo, mini-reproductor, selector de vista
/// (Cuadrícula / Mazos / Lista) y el contenido. Tema claro.
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @State private var path: [Podcast] = []
    @State private var showSettings = false

    private let gridColumns = [GridItem(.adaptive(minimum: 72, maximum: 110), spacing: 9)]
    private let deckColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        @Bindable var store = store

        NavigationStack(path: $path) {
            ZStack {
                Theme.background().ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header
                            greeting

                            Picker("Vista", selection: $store.libraryLayout) {
                                ForEach(LibraryLayout.allCases, id: \.self) { layout in
                                    Text(layout.label).tag(layout)
                                }
                            }
                            .pickerStyle(.segmented)

                            content
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                    }
                    .refreshable { await store.refresh(downloads: downloads) }

                    if let episode = store.nowPlaying {
                        MiniPlayer(episode: episode)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Podcast.self) { podcast in
                PodcastDetailView(podcast: podcast)
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear(perform: applyPreviewIfNeeded)
    }

    // MARK: - Contenido según la vista elegida

    @ViewBuilder
    private var content: some View {
        switch store.libraryLayout {
        case .grid: gridView
        case .decks: decksView
        case .list: listView
        }
    }

    private var gridView: some View {
        LazyVGrid(columns: gridColumns, spacing: 9) {
            ForEach(store.podcasts) { podcast in
                NavigationLink(value: podcast) {
                    PodcastCover(podcast: podcast, size: 80)
                }
                .buttonStyle(.plain)
                .contextMenu { podcastMenu(podcast) }
            }
        }
    }

    private var decksView: some View {
        LazyVGrid(columns: deckColumns, spacing: 18) {
            ForEach(store.podcasts) { podcast in
                NavigationLink(value: podcast) {
                    PodcastDeck(podcast: podcast)
                }
                .buttonStyle(.plain)
                .contextMenu { podcastMenu(podcast) }
            }
        }
        .padding(.top, 6)
    }

    private var listView: some View {
        VStack(spacing: 0) {
            ForEach(store.podcasts) { podcast in
                NavigationLink(value: podcast) {
                    PodcastListRow(podcast: podcast)
                }
                .buttonStyle(.plain)
                .contextMenu { podcastMenu(podcast) }
                Divider().overlay(Theme.divider)
            }
        }
    }

    @ViewBuilder
    private func podcastMenu(_ podcast: Podcast) -> some View {
        Button { store.clearDownloads(for: podcast.id) } label: {
            Label("Borrar descargas", systemImage: "trash")
        }
        Button(role: .destructive) { store.removePodcast(podcast.id) } label: {
            Label("Dejar de seguir", systemImage: "xmark.circle")
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack {
            Text("unicast")
                .font(displayFont(size: 26))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            HStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
            }
            .font(.system(size: 19))
            .foregroundStyle(Theme.accent)
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Buenas noches")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            (
                Text("Tienes ").foregroundStyle(Theme.textPrimary)
                + Text("\(store.newEpisodeCount) episodios").foregroundStyle(Theme.accent)
                + Text(" por escuchar").foregroundStyle(Theme.textPrimary)
            )
            .font(displayFont(size: 27))
        }
    }

    /// Permite capturar pantallas concretas en el simulador lanzando con UNICAST_PREVIEW=...
    private func applyPreviewIfNeeded() {
        switch ProcessInfo.processInfo.environment["UNICAST_PREVIEW"] {
        case "podcastDetail", "podcastSettings", "select":
            if path.isEmpty, let first = store.podcasts.first { path = [first] }
        case "player":
            store.isPlayerPresented = true
        case "settings", "background":
            showSettings = true
        case "decks":
            store.libraryLayout = .decks
        case "list":
            store.libraryLayout = .list
        default:
            break
        }
    }
}
