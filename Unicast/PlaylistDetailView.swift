import SwiftUI

/// Interior de una lista de reproducción: si es inteligente lo avisa, y los episodios
/// se reordenan a mano arrastrando (ese orden manda en la reproducción).
struct PlaylistDetailView: View {
    @Environment(AppStore.self) private var store
    let playlist: Playlist

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
                        .deleteDisabled(true)
                }
                .onMove { source, destination in
                    store.movePlaylistItems(current.id, from: source, to: destination)
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
                Image(systemName: "ellipsis").foregroundStyle(Theme.accent)
            }
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: episode.colorHex))
                .frame(width: 38, height: 38)
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
