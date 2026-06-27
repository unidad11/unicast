import Foundation

/// Lo que Unicast guarda en disco entre sesiones.
struct AppState: Codable {
    var podcasts: [Podcast]
    var playlists: [Playlist]
    var backgroundStyle: BackgroundStyle
    var showNewCountBadges: Bool
    var libraryLayout: LibraryLayout
    var wifiOnlyDownloads: Bool
    var defaultDownloadLimit: DownloadLimit
    var nowPlayingID: UUID?
}

/// Guarda y carga el estado en Application Support/unicast_state.json.
enum Persistence {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("unicast_state.json")
    }

    static func save(_ state: AppState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> AppState? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else { return nil }
        return state
    }
}
