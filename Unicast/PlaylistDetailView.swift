import SwiftUI

/// Interior de una lista de reproducción: si es inteligente lo avisa, y los episodios
/// se reordenan a mano arrastrando (ese orden manda en la reproducción).
struct PlaylistDetailView: View {
    @Environment(AppStore.self) private var store
    let playlist: Playlist

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showAddEpisodes = false
    @State private var showAddPodcast = false

    private var current: Playlist { store.playlists.first { $0.id == playlist.id } ?? playlist }
    private var episodes: [Episode] { store.episodes(in: current) }

    var body: some View {
        ZStack {
            Theme.background(store.backgroundStyle).ignoresSafeArea()

            List {
                if current.isSmart {
                    smartBanner
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                }

                ForEach(episodes) { episode in
                    PlaylistEpisodeRow(episode: episode)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                }
                .onMove { source, destination in
                    store.movePlaylistItems(current.id, from: source, to: destination)
                }
                .onDelete { offsets in
                    for id in offsets.map({ episodes[$0].id }) {
                        store.removeEpisodeFromPlaylist(id, playlistID: current.id)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = current.name
                        showRename = true
                    } label: {
                        Label("Cambiar nombre", systemImage: "pencil")
                    }
                    Button {
                        showAddEpisodes = true
                    } label: {
                        Label("Añadir episodios", systemImage: "plus.circle")
                    }
                    if current.isSmart {
                        Button {
                            showAddPodcast = true
                        } label: {
                            Label("Añadir podcast", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.accent)
                }
            }
        }
        .alert("Cambiar nombre", isPresented: $showRename) {
            TextField("Nombre de la lista", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") { store.renamePlaylist(current.id, name: renameText) }
        }
        .sheet(isPresented: $showAddEpisodes) {
            AddEpisodesSheet(playlist: current)
        }
        .sheet(isPresented: $showAddPodcast) {
            AddSourcePodcastSheet(playlist: current)
        }
        .tint(Theme.accent)
    }

    private var smartBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 15))
            Text("Inteligente · los episodios nuevos de tus podcasts entran aquí solos, en el orden que marques.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(
            LinearGradient(colors: [.white, Color(hex: "F1EDFF")], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.accent.opacity(0.3)))
    }
}

/// Una fila de episodio dentro de una lista. El asa de arrastre la añade la propia lista.
private struct PlaylistEpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 10) {
            EpisodeCover(episode: episode)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(episode.podcastTitle) · \(formatDuration(episode.duration))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

/// Añade episodios descargados (agrupados por podcast) a una lista que ya existe.
private struct AddEpisodesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist

    @State private var selected: Set<UUID> = []

    private var groups: [(podcast: Podcast, episodes: [Episode])] {
        let already = Set(playlist.episodeIDs)
        return store.podcasts.compactMap { podcast in
            let episodes = podcast.downloadedEpisodes.filter { !already.contains($0.id) }
            return episodes.isEmpty ? nil : (podcast, episodes)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(store.backgroundStyle).ignoresSafeArea()

                List {
                    if groups.isEmpty {
                        Section {
                            Text("No hay episodios descargados nuevos que añadir.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .listRowBackground(Theme.surface)
                    } else {
                        ForEach(groups, id: \.podcast.id) { group in
                            Section(group.podcast.title) {
                                ForEach(group.episodes) { episode in
                                    Button { toggle(episode.id) } label: { row(episode) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .listRowBackground(Theme.surface)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.textPrimary)
            }
            .navigationTitle("Añadir episodios")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Añadir") {
                        store.addEpisodes(Array(selected), to: playlist.id)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func row(_ episode: Episode) -> some View {
        HStack(spacing: 10) {
            EpisodeCover(episode: episode, size: 34, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(episode.title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(episode.podcastTitle).font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: selected.contains(episode.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected.contains(episode.id) ? Theme.accent : Theme.textMuted)
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

/// Añade un podcast más como fuente de una lista inteligente (con sus descargados actuales).
private struct AddSourcePodcastSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist

    private var candidates: [Podcast] {
        store.podcasts.filter { !playlist.sourcePodcastOrder.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(store.backgroundStyle).ignoresSafeArea()

                List {
                    if candidates.isEmpty {
                        Section {
                            Text("Todos tus podcasts ya son fuente de esta lista.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .listRowBackground(Theme.surface)
                    } else {
                        Section("Añadir como fuente") {
                            ForEach(candidates) { podcast in
                                Button {
                                    store.addSourcePodcast(podcast.id, to: playlist.id)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        PodcastCover(podcast: podcast, size: 34, showTitle: false)
                                        Text(podcast.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.textPrimary)
            }
            .navigationTitle("Añadir podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancelar") { dismiss() } }
            }
        }
    }
}
