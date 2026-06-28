import SwiftUI

/// Hoja para enviar los episodios seleccionados a una lista (existente o nueva).
struct AddToPlaylistView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let episodeIDs: [UUID]
    let onDone: () -> Void
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background().ignoresSafeArea()

                List {
                    Section("Tus listas") {
                        if store.playlists.isEmpty {
                            Text("No tienes listas todavía.")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(store.playlists) { playlist in
                            Button {
                                store.addEpisodes(episodeIDs, to: playlist.id)
                                finish()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: playlist.isSmart ? "bolt.fill" : "music.note.list")
                                        .foregroundStyle(playlist.isSmart ? Theme.accent : Theme.textSecondary)
                                    Text(playlist.name).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text("\(playlist.episodeIDs.count)").foregroundStyle(Theme.textMuted)
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)

                    Section("Nueva lista") {
                        HStack {
                            TextField("", text: $newName,
                                      prompt: Text("Nombre de la lista").foregroundStyle(Theme.textMuted))
                                .foregroundStyle(Theme.textPrimary)
                            Button("Crear") {
                                store.createPlaylist(name: newName, episodeIDs: episodeIDs)
                                finish()
                            }
                            .foregroundStyle(Theme.accent)
                            .disabled(newName.trimmed.isEmpty)
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)
            }
            .navigationTitle("Añadir a lista (\(episodeIDs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { dismiss() } }
            }
        }
    }

    private func finish() {
        onDone()
        dismiss()
    }
}
