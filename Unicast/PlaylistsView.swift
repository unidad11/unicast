import SwiftUI

/// Índice de listas de reproducción. Las inteligentes se marcan con un rayo.
struct PlaylistsView: View {
    @Environment(AppStore.self) private var store
    @State private var path: [Playlist] = []
    @State private var showCreate = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background(store.backgroundStyle).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Listas")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            Button { showCreate = true } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(Theme.accent, in: Circle())
                            }
                        }
                        .padding(.bottom, 12)

                        ForEach(store.playlists) { playlist in
                            NavigationLink(value: playlist) {
                                PlaylistRow(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Theme.divider)
                        }
                    }
                    .padding(16)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Playlist.self) { playlist in
                    PlaylistDetailView(playlist: playlist)
                }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showCreate) { CreatePlaylistView() }
        .onAppear {
            switch ProcessInfo.processInfo.environment["UNICAST_PREVIEW"] {
            case "playlistDetail":
                if path.isEmpty, let smart = store.playlists.first(where: { $0.isSmart }) {
                    path = [smart]
                }
            case "createPlaylist", "createSmart":
                showCreate = true
            default:
                break
            }
        }
    }
}

/// Una fila del índice de listas.
private struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: playlist.isSmart ? "bolt.fill" : "music.note.list")
                        .font(.system(size: 18))
                        .foregroundStyle(playlist.isSmart ? Theme.accentLight : Theme.textSecondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if playlist.isSmart {
                    Label("Inteligente · \(playlist.episodeIDs.count) episodios", systemImage: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentLight)
                } else {
                    Text("\(playlist.episodeIDs.count) episodios")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 10)
    }
}
