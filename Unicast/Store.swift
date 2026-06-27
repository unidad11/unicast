import SwiftUI
import Observation

/// Estado global de Unicast. Las vistas leen y escriben aquí.
///
/// De momento guarda todo en memoria con datos de ejemplo. Cuando conectemos los feeds
/// reales y la persistencia, solo cambiará el interior de esta clase: las vistas seguirán igual.
@Observable
final class AppStore {
    // Contenido
    var podcasts: [Podcast] = []
    var playlists: [Playlist] = []

    // Ajustes generales
    var backgroundStyle: BackgroundStyle = .blueNight
    var showNewCountBadges: Bool = false   // contador de nuevos sobre pósters: OFF de fábrica
    var libraryLayout: LibraryLayout = .grid
    var selectedTab: Int = 0   // pestaña activa del TabView
    var wifiOnlyDownloads: Bool = true
    var defaultDownloadLimit: DownloadLimit = .last(5)

    // Reproductor
    var nowPlaying: Episode?
    var isPlaying: Bool = false
    var isPlayerPresented: Bool = false   // reproductor a pantalla completa abierto

    /// Cuántos episodios nuevos hay en total (para el saludo de la pantalla de inicio).
    var newEpisodeCount: Int {
        podcasts.reduce(0) { $0 + $1.episodes.filter { $0.isDownloaded && !$0.isPlayed }.count }
    }

    /// Busca un podcast por su id.
    func podcast(id: UUID) -> Podcast? { podcasts.first { $0.id == id } }

    /// Arranca un episodio en el reproductor.
    func play(_ episode: Episode) {
        nowPlaying = episode
        isPlaying = true
    }

    /// Rellena la carátula del episodio con la del podcast (para el Now Playing / isla).
    func enrich(_ episode: Episode) -> Episode {
        guard episode.artworkURL == nil,
              let podcast = podcasts.first(where: { $0.title == episode.podcastTitle }) else { return episode }
        var copy = episode
        copy.artworkURL = podcast.artworkURL
        return copy
    }

    /// Borra un episodio de un podcast (deslizar para borrar).
    func removeEpisode(_ episodeID: UUID, from podcastID: UUID) {
        guard let index = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        podcasts[index].episodes.removeAll { $0.id == episodeID }
        DownloadManager.deleteFile(for: episodeID)
        save()
    }

    /// Borra varios episodios a la vez (selección múltiple).
    func removeEpisodes(_ episodeIDs: Set<UUID>, from podcastID: UUID) {
        guard let index = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        podcasts[index].episodes.removeAll { episodeIDs.contains($0.id) }
        for id in episodeIDs { DownloadManager.deleteFile(for: id) }
        save()
    }

    /// Añade episodios a una lista (selección múltiple → enviar a lista).
    func addEpisodes(_ episodeIDs: [UUID], to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for id in episodeIDs where !playlists[index].episodeIDs.contains(id) {
            playlists[index].episodeIDs.append(id)
        }
        save()
    }

    /// Guarda la posición exacta de un episodio (para retomarlo donde se dejó).
    func updatePlaybackPosition(_ episodeID: UUID, _ time: TimeInterval) {
        for pi in podcasts.indices {
            if let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) {
                podcasts[pi].episodes[ei].playbackPosition = time
                return
            }
        }
    }

    /// Al terminar un episodio: autoborrado (quita el audio y lo saca de Descargados → vuelve a Todos).
    func handleFinished(_ episodeID: UUID) {
        DownloadManager.deleteFile(for: episodeID)
        for pi in podcasts.indices {
            if let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) {
                podcasts[pi].episodes[ei].isDownloaded = false
                podcasts[pi].episodes[ei].isPlayed = true   // escuchado: desaparece de Todos
                podcasts[pi].episodes[ei].playbackPosition = 0
                break
            }
        }
        save()
    }

    /// Siguiente episodio a reproducir en cadena, según el sentido continuo del podcast (punto 5).
    func nextEpisode(after episodeID: UUID) -> Episode? {
        guard let podcast = podcasts.first(where: { $0.episodes.contains { $0.id == episodeID } }) else { return nil }
        // La reproducción continua va SOLO entre los descargados.
        let pool = podcast.downloadedEpisodes
        let ordered = podcast.continuousDirection == .posteriores
            ? pool.sorted { $0.publishedAt < $1.publishedAt }
            : pool.sorted { $0.publishedAt > $1.publishedAt }
        guard let index = ordered.firstIndex(where: { $0.id == episodeID }),
              index + 1 < ordered.count else { return nil }
        return ordered[index + 1]
    }

    /// Marca un episodio como descargado.
    func markDownloaded(_ episodeID: UUID, in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].isDownloaded = true
        save()
    }

    /// Deja de seguir un podcast (lo quita de la biblioteca).
    func removePodcast(_ id: UUID) {
        podcasts.removeAll { $0.id == id }
    }

    /// Crea una lista manual con los episodios indicados. Devuelve su id.
    @discardableResult
    func createPlaylist(name: String, episodeIDs: [UUID]) -> UUID {
        let playlist = Playlist(name: name.isEmpty ? "Nueva lista" : name, episodeIDs: episodeIDs)
        playlists.append(playlist)
        return playlist.id
    }

    /// Convierte una lista en inteligente: sus podcasts de origen pasan a ser las "fuentes",
    /// en el orden en que aparecen los episodios (esa es la prioridad por podcast).
    func makeSmart(_ playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var order: [UUID] = []
        for episodeID in playlists[index].episodeIDs {
            if let podcast = podcasts.first(where: { $0.episodes.contains { $0.id == episodeID } }),
               !order.contains(podcast.id) {
                order.append(podcast.id)
            }
        }
        playlists[index].isSmart = true
        playlists[index].sourcePodcastOrder = order
    }

    /// Sigue un podcast (lo añade a la biblioteca) si no estaba ya.
    func subscribe(_ podcast: Podcast, downloads: DownloadManager) {
        guard !podcasts.contains(where: { $0.title == podcast.title }) else { return }
        podcasts.append(podcast)
        save()
        applyAutoDownload(for: podcast.id, using: downloads)
    }

    /// Mantiene descargados los últimos N episodios (según el límite del podcast) y borra los
    /// descargados más antiguos que sobren (rotación). N = todos si el límite es .all.
    func applyAutoDownload(for podcastID: UUID, using downloads: DownloadManager) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }), podcasts[pi].autoDownload else { return }
        let podcast = podcasts[pi]
        let byNewest = podcast.episodes.sorted { $0.publishedAt > $1.publishedAt }
        let target: Int
        switch podcast.downloadLimit {
        case .all: target = byNewest.count
        case .last(let n): target = n
        }
        let keep = Array(byNewest.prefix(target))
        let keepIDs = Set(keep.map(\.id))
        // Descargar los que falten (no escuchados).
        for ep in keep where !ep.isDownloaded && !ep.isPlayed {
            downloads.download(ep) { [weak self] in self?.markDownloaded(ep.id, in: podcastID) }
        }
        // Rotación: borrar los descargados antiguos que ya no entran (sin empezar a escuchar).
        for ep in podcast.episodes where ep.isDownloaded && !keepIDs.contains(ep.id) && ep.playbackPosition == 0 {
            removeFromDownloads(ep.id, in: podcastID)
        }
    }

    /// Quita un episodio de Descargados (borra el audio) sin marcarlo escuchado — para la rotación.
    func removeFromDownloads(_ episodeID: UUID, in podcastID: UUID) {
        DownloadManager.deleteFile(for: episodeID)
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].isDownloaded = false
        save()
    }

    /// Borra TODAS las descargas de un podcast (el audio), dejando los episodios en "Todos".
    func clearDownloads(for podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        for ep in podcasts[pi].episodes where ep.isDownloaded { DownloadManager.deleteFile(for: ep.id) }
        for ei in podcasts[pi].episodes.indices { podcasts[pi].episodes[ei].isDownloaded = false }
        save()
    }

    /// ¿Está ya seguido este podcast (por título)?
    func isFollowing(_ podcast: Podcast) -> Bool {
        podcasts.contains { $0.title == podcast.title }
    }

    /// Refresca los feeds reales: trae los episodios nuevos sin perder el estado de los que ya hay.
    func refresh(downloads: DownloadManager) async {
        for index in podcasts.indices {
            guard let feed = podcasts[index].feedURL,
                  let fresh = await PodcastService.fetchPodcast(feedURL: feed, colorHex: podcasts[index].colorHex)
            else { continue }
            var updated = podcasts[index]
            updated.summary = fresh.summary.isEmpty ? updated.summary : fresh.summary
            updated.artworkURL = fresh.artworkURL ?? updated.artworkURL
            let knownTitles = Set(updated.episodes.map(\.title))
            let newEpisodes = fresh.episodes.filter { !knownTitles.contains($0.title) }
            updated.episodes = newEpisodes + updated.episodes   // los nuevos, primero
            podcasts[index] = updated
            applyAutoDownload(for: updated.id, using: downloads)   // baja nuevos y rota el límite
        }
        save()
    }

    /// Busca un episodio por su id en toda la biblioteca.
    func episode(id: UUID) -> Episode? {
        for podcast in podcasts {
            if let episode = podcast.episodes.first(where: { $0.id == id }) { return episode }
        }
        return nil
    }

    /// Episodios de una lista, en su orden actual.
    func episodes(in playlist: Playlist) -> [Episode] {
        playlist.episodeIDs.compactMap { episode(id: $0) }
    }

    /// Reordena a mano los episodios de una lista (arrastrar).
    func movePlaylistItems(_ playlistID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].episodeIDs.move(fromOffsets: source, toOffset: destination)
    }

    /// Crea un `AppStore` ya poblado con datos de ejemplo (para ver la interfaz).
    /// Crea el store cargando lo guardado en disco; la primera vez usa datos de ejemplo.
    static func loadOrSample() -> AppStore {
        let store = AppStore()
        if let state = Persistence.load() {
            store.apply(state)
        } else {
            store.podcasts = SampleData.podcasts
            store.playlists = SampleData.playlists
            store.nowPlaying = SampleData.nowPlaying
            store.save()
        }
        return store
    }

    /// Vuelca un estado cargado de disco al store.
    func apply(_ state: AppState) {
        podcasts = state.podcasts
        playlists = state.playlists
        backgroundStyle = state.backgroundStyle
        showNewCountBadges = state.showNewCountBadges
        libraryLayout = state.libraryLayout
        wifiOnlyDownloads = state.wifiOnlyDownloads
        defaultDownloadLimit = state.defaultDownloadLimit
        nowPlaying = state.nowPlayingID.flatMap { episode(id: $0) }
    }

    /// Foto del estado actual.
    func snapshot() -> AppState {
        AppState(podcasts: podcasts, playlists: playlists, backgroundStyle: backgroundStyle,
                 showNewCountBadges: showNewCountBadges, libraryLayout: libraryLayout,
                 wifiOnlyDownloads: wifiOnlyDownloads, defaultDownloadLimit: defaultDownloadLimit,
                 nowPlayingID: nowPlaying?.id)
    }

    /// Guarda el estado en disco.
    func save() { Persistence.save(snapshot()) }
}
