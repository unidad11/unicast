import SwiftUI

/// Ajustes de UN podcast concreto: descargas, orden, reproducción y avisos.
/// Se abre desde el "···" de la pantalla del podcast. Todo aplica solo a ese podcast.
struct PodcastSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let podcastID: UUID

    private var index: Int? { store.podcasts.firstIndex { $0.id == podcastID } }

    var body: some View {
        @Bindable var store = store

        ZStack {
            Theme.background(store.backgroundStyle).ignoresSafeArea()

            if let i = index {
                List {
                    Section {
                        HStack(spacing: 11) {
                            PodcastCover(podcast: store.podcasts[i], size: 50)
                            Text(store.podcasts[i].title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .listRowBackground(Color.clear)
                    }

                    Section("Descargas") {
                        Toggle("Descargar automáticamente", isOn: $store.podcasts[i].autoDownload)
                        pickerRow("Cuántos guardar", value: store.podcasts[i].downloadLimit.label) {
                            Button("Todos") { store.podcasts[i].downloadLimit = .all }
                            Button("Los 5 últimos") { store.podcasts[i].downloadLimit = .last(5) }
                            Button("Los 10 últimos") { store.podcasts[i].downloadLimit = .last(10) }
                            Button("Los 20 últimos") { store.podcasts[i].downloadLimit = .last(20) }
                        }
                        Toggle("Borrar al terminar", isOn: $store.podcasts[i].autoDeleteOnFinish)
                    }
                    .listRowBackground(Theme.surface)

                    Section("Orden y reproducción") {
                        pickerRow("Ordenar episodios", value: store.podcasts[i].sortOrder.label) {
                            ForEach(EpisodeSort.allCases, id: \.self) { option in
                                Button(option.label) { store.podcasts[i].sortOrder = option }
                            }
                        }
                        pickerRow("Reproducción continua", value: store.podcasts[i].continuousDirection.label) {
                            ForEach(PlayDirection.allCases, id: \.self) { option in
                                Button(option.label) { store.podcasts[i].continuousDirection = option }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)

                    Section("Avisos") {
                        Toggle("Notificar nuevos episodios", isOn: $store.podcasts[i].notifyNew)
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        Button(role: .destructive) {
                            store.removePodcast(podcastID)
                            dismiss()
                        } label: {
                            Text("Dejar de seguir").frame(maxWidth: .infinity)
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .tint(Theme.accent)
                .foregroundStyle(.white)
            }
        }
        .navigationTitle("Ajustes del podcast")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
    }

    /// Una fila con un menú desplegable (etiqueta + valor actual + opciones).
    private func pickerRow<Content: View>(_ title: String, value: String,
                                          @ViewBuilder options: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                options()
            } label: {
                HStack(spacing: 4) {
                    Text(value).foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
