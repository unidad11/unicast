import SwiftUI

/// Cuánto ocupan las descargas: total y por podcast (estilo Overcast).
struct StorageView: View {
    @Environment(AppStore.self) private var store

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let count: Int
        let bytes: Int64
    }

    private var rows: [Row] {
        store.podcasts.compactMap { podcast in
            let downloaded = podcast.episodes.filter(\.isDownloaded)
            guard !downloaded.isEmpty else { return nil }
            let bytes = downloaded.reduce(Int64(0)) { $0 + DownloadManager.fileSize(for: $1.id) }
            return Row(id: podcast.id, title: podcast.title, count: downloaded.count, bytes: bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private var totalCount: Int { rows.reduce(0) { $0 + $1.count } }
    private var totalBytes: Int64 { rows.reduce(Int64(0)) { $0 + $1.bytes } }

    var body: some View {
        ZStack {
            Theme.background(store.backgroundStyle).ignoresSafeArea()

            List {
                Section {
                    HStack {
                        Text("Total descargado").foregroundStyle(.white)
                        Spacer()
                        Text("\(totalCount) capítulos · \(format(totalBytes))")
                            .foregroundStyle(Theme.accentLight)
                    }
                }
                .listRowBackground(Theme.surface)

                Section("Por podcast") {
                    if rows.isEmpty {
                        Text("No hay nada descargado.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(rows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).foregroundStyle(.white).lineLimit(1)
                                Text("\(row.count) capítulos")
                                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Text(format(row.bytes)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .tint(Theme.accent)
            .foregroundStyle(.white)
        }
        .navigationTitle("Almacenamiento")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
