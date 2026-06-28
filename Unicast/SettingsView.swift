import SwiftUI

/// Rutas dentro de los ajustes generales.
enum SettingsRoute: Hashable { case storage }

/// Ajustes generales de Unicast: apariencia, descargas e importar/exportar OPML.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []

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
                    }
                    .listRowBackground(Theme.surface)

                    Section("Tus podcasts") {
                        Label("Importar OPML", systemImage: "square.and.arrow.down")
                        Label("Exportar OPML", systemImage: "square.and.arrow.up")
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
                }
            }
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
