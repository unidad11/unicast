import SwiftUI

/// Rutas dentro de los ajustes generales.
enum SettingsRoute: Hashable { case storage, diagnostics }

/// Ajustes generales de Unicast: apariencia, descargas e importar/exportar OPML.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []
    @State private var opmlURL: URL?
    @State private var showImporter = false

    var body: some View {
        @Bindable var store = store

        NavigationStack(path: $path) {
            ZStack {
                Theme.background(store.backgroundStyle).ignoresSafeArea()

                List {
                    Section("Apariencia") {
                        Toggle("Contador de nuevos en pósters", isOn: $store.showNewCountBadges)
                        pickerRow("Pantalla de inicio", value: store.libraryLayout.label) {
                            ForEach(LibraryLayout.allCases, id: \.self) { option in
                                Button(option.label) { store.libraryLayout = option }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)

                    Section("Descargas") {
                        Toggle("Descargar solo con WiFi", isOn: $store.wifiOnlyDownloads)
                        pickerRow("Guardar por defecto", value: store.defaultDownloadLimit.label) {
                            Button("Todos") { store.defaultDownloadLimit = .all }
                            Button("Los 5 últimos") { store.defaultDownloadLimit = .last(5) }
                            Button("Los 10 últimos") { store.defaultDownloadLimit = .last(10) }
                        }
                        NavigationLink(value: SettingsRoute.storage) {
                            Label("Almacenamiento", systemImage: "internaldrive")
                        }
                        NavigationLink(value: SettingsRoute.diagnostics) {
                            Label("Diagnóstico", systemImage: "stethoscope")
                        }
                    }
                    .listRowBackground(Theme.surface)

                    Section("Tus podcasts") {
                        // Esta fila era un Label suelto: no hacía NADA al tocarla, aunque la
                        // importación existía y funcionaba escondida en Buscar → Añadir podcast.
                        Button { showImporter = true } label: {
                            Label("Importar OPML", systemImage: "square.and.arrow.down")
                                .foregroundStyle(Theme.textPrimary)
                        }
                        if let opmlURL {
                            ShareLink(item: opmlURL) {
                                Label("Exportar OPML", systemImage: "square.and.arrow.up")
                            }
                        } else {
                            Label("Exportar OPML", systemImage: "square.and.arrow.up")
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .storage: StorageView()
                case .diagnostics: DownloadDiagnosticsView()
                }
            }
            .task { opmlURL = OPMLExporter.writeTempFile(from: store.podcasts) }
            .sheet(isPresented: $showImporter) { AddPodcastView() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() } }
            }
        }
    }

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
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
