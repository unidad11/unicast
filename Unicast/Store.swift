import SwiftUI
import Observation

/// Estado global de Unicast. Las vistas leen y escriben aquí.
///
/// De momento guarda todo en memoria con datos de ejemplo. Cuando conectemos los feeds
/// reales y la persistencia, solo cambiará el interior de esta clase: las vistas seguirán igual.
/// Lo que consiguió un refresco: cuántos podcasts traían episodios nuevos, cuántos fallaron
/// (red, timeout...) y cuántos se intentaron en total. Sirve para el registro de despertares
/// (`WakeLog`) — sin esto no había forma de saber si un refresco en segundo plano llegó a hacer
/// algo o si iOS lo cortó antes de tiempo.
struct RefreshSummary {
    let changed: Int
    let failed: Int
    let total: Int
    let networkSeconds: Double
    let fastestDetectionSeconds: Double?
}

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
        discard([episodeID], in: podcastID)
    }

    /// Borra varios episodios a la vez (selección múltiple).
    func removeEpisodes(_ episodeIDs: Set<UUID>, from podcastID: UUID) {
        discard(Array(episodeIDs), in: podcastID)
    }

    /// Descarta episodios: borra el audio y los marca escuchados SIN sacarlos del registro.
    /// Clave anti-bug: si se eliminaran del todo, el siguiente refresco los traería como
    /// "nuevos" y el auto-descargar los volvería a bajar (los 4 que resucitaban).
    private func discard(_ episodeIDs: [UUID], in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        let ids = Set(episodeIDs)
        for ei in podcasts[pi].episodes.indices where ids.contains(podcasts[pi].episodes[ei].id) {
            DownloadManager.deleteFile(for: podcasts[pi].episodes[ei].id)
            podcasts[pi].episodes[ei].isDownloaded = false
            podcasts[pi].episodes[ei].isPlayed = true   // apagado en "Todos"; nunca se re-descarga
            podcasts[pi].episodes[ei].playbackPosition = 0
        }
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

    /// Guarda los capítulos descargados del JSON aparte, para no volver a pedirlos cada vez.
    func setChapters(_ chapters: [Chapter], for episodeID: UUID) {
        for pi in podcasts.indices {
            if let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) {
                podcasts[pi].episodes[ei].chapters = chapters
                save()
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

    /// Marca un episodio como descargado buscando por su cuenta a qué podcast pertenece. Se usa
    /// cuando la descarga termina con la app cerrada: ahí no hay ninguna pantalla abierta que sepa
    /// de qué podcast venía.
    func markDownloaded(_ episodeID: UUID) {
        guard let podcast = podcasts.first(where: { $0.episodes.contains { $0.id == episodeID } }) else { return }
        markDownloaded(episodeID, in: podcast.id)
    }

    /// Marca un episodio como descargado.
    func markDownloaded(_ episodeID: UUID, in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].isDownloaded = true
        save()
    }

    /// Pone al día la marca "Descargado" con lo que hay de verdad en disco, y vuelve a bajar lo
    /// que falte y estuviera a medio escuchar. Devuelve cuántos episodios se habían quedado sin audio.
    ///
    /// Hace falta porque el audio vivía en Caches, una carpeta que iOS vacía por su cuenta cuando
    /// le falta espacio (empezando por los archivos grandes, o sea los episodios largos). El
    /// episodio decía "Descargado" sin tener mp3, y el reproductor tiraba de streaming en silencio.
    /// NO se toca `playbackPosition`: el episodio se retoma donde se dejó.
    ///
    /// También al revés: si el mp3 está en disco pero el episodio no figura como descargado, se
    /// marca. Es la red de seguridad para las descargas que iOS termina con la app cerrada, donde
    /// no hay nadie escuchando para apuntarlo.
    @discardableResult
    func reconcileDownloads(using downloads: DownloadManager) -> Int {
        var missing: [(episode: Episode, podcastID: UUID)] = []
        var recovered = 0
        for pi in podcasts.indices {
            for ei in podcasts[pi].episodes.indices {
                let onDisk = DownloadManager.isDownloaded(podcasts[pi].episodes[ei].id)
                switch (podcasts[pi].episodes[ei].isDownloaded, onDisk) {
                case (true, false):     // decía "Descargado" pero el audio ya no está
                    podcasts[pi].episodes[ei].isDownloaded = false
                    missing.append((podcasts[pi].episodes[ei], podcasts[pi].id))
                case (false, true):     // el audio está pero nadie lo marcó: descarga terminada
                    podcasts[pi].episodes[ei].isDownloaded = true   // con la app cerrada
                    recovered += 1
                default:
                    break
                }
            }
        }
        guard !missing.isEmpty || recovered > 0 else { return 0 }
        save()
        // Los que estaban a medio escuchar se rebajan ya, sin esperar al refresco: pueden quedar
        // fuera de la ventana de auto-descarga y entonces no los bajaría nadie.
        for item in missing where item.episode.playbackPosition > 0 {
            downloads.download(item.episode) { [weak self] in
                self?.markDownloaded(item.episode.id, in: item.podcastID)
            }
        }
        return missing.count
    }

    /// Deja de seguir un podcast: borra sus audios descargados (que no queden huérfanos
    /// ocupando espacio) y lo quita de la biblioteca.
    func removePodcast(_ id: UUID) {
        if let podcast = podcasts.first(where: { $0.id == id }) {
            for ep in podcast.episodes where ep.isDownloaded { DownloadManager.deleteFile(for: ep.id) }
        }
        podcasts.removeAll { $0.id == id }
        save()
    }

    /// Crea una lista manual con los episodios indicados. Devuelve su id.
    @discardableResult
    func createPlaylist(name: String, episodeIDs: [UUID]) -> UUID {
        let playlist = Playlist(name: name.isEmpty ? "Nueva lista" : name, episodeIDs: episodeIDs)
        playlists.append(playlist)
        save()
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
        save()
    }

    /// Cambia el nombre de una lista.
    func renamePlaylist(_ playlistID: UUID, name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        playlists[index].name = name
        save()
    }

    /// Quita un episodio de una lista (no borra el episodio de su podcast, solo sale de esta lista).
    func removeEpisodeFromPlaylist(_ episodeID: UUID, playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].episodeIDs.removeAll { $0 == episodeID }
        save()
    }

    /// Añade un podcast como fuente de una lista inteligente y mete ya sus descargados actuales
    /// (si no, habría que esperar a que publicara algo nuevo para ver el primer episodio).
    func addSourcePodcast(_ podcastID: UUID, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              let podcast = podcast(id: podcastID) else { return }
        if !playlists[index].sourcePodcastOrder.contains(podcastID) {
            playlists[index].sourcePodcastOrder.append(podcastID)
        }
        let already = Set(playlists[index].episodeIDs)
        let newIDs = podcast.downloadedEpisodes.map(\.id).filter { !already.contains($0) }
        playlists[index].episodeIDs.append(contentsOf: newIDs)
        save()
    }

    /// Sigue un podcast (lo añade a la biblioteca) si no estaba ya.
    func subscribe(_ podcast: Podcast, downloads: DownloadManager) {
        guard !podcasts.contains(where: { $0.title == podcast.title }) else { return }
        var fresh = podcast
        // Fecha de alta = corte. Se bajan los 4 más recientes (base) y, de ahí en adelante,
        // lo que se publique. NUNCA el histórico anterior a esa fecha.
        let byNewest = fresh.episodes.sorted { $0.publishedAt > $1.publishedAt }
        let base = 4
        fresh.downloadFromDate = byNewest.count >= base ? byNewest[base - 1].publishedAt
                                                        : (byNewest.last?.publishedAt ?? Date())
        podcasts.append(fresh)
        save()
        applyAutoDownload(for: fresh.id, using: downloads)
    }

    /// Mantiene descargados los últimos N episodios (según el límite del podcast) y borra los
    /// descargados más antiguos que sobren (rotación). N = todos si el límite es .all.
    func applyAutoDownload(for podcastID: UUID, using downloads: DownloadManager) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }), podcasts[pi].autoDownload else { return }
        // Migración: si un podcast viejo no tiene fecha de alta, la fijo al 4º más reciente
        // (así no vuelve a bajar el histórico).
        if podcasts[pi].downloadFromDate == nil {
            let s = podcasts[pi].episodes.sorted { $0.publishedAt > $1.publishedAt }
            podcasts[pi].downloadFromDate = s.count >= 4 ? s[3].publishedAt : (s.last?.publishedAt ?? Date())
        }
        let podcast = podcasts[pi]
        let from = podcast.downloadFromDate ?? .distantPast
        // SOLO episodios publicados desde el alta (la base + los nuevos). Nunca el histórico.
        let eligible = podcast.episodes.filter { $0.publishedAt >= from }.sorted { $0.publishedAt > $1.publishedAt }
        let target: Int
        switch podcast.downloadLimit {
        case .all: target = eligible.count
        case .last(let n): target = n
        }
        let keep = Array(eligible.prefix(target))
        let keepIDs = Set(keep.map(\.id))
        // También se pregunta al disco, no solo al flag en memoria: si `onFinished` no llegó a
        // marcar una descarga de la noche (el caso que arregla el bug de arriba, en versiones
        // futuras si volviera a colarse uno parecido), sin este chequeo se re-descargaría el
        // mismo mp3 entero en cada refresco, varias veces al día.
        for ep in keep where !ep.isDownloaded && !ep.isPlayed && !DownloadManager.isDownloaded(ep.id) {
            downloads.download(ep) { [weak self] in self?.markDownloaded(ep.id, in: podcastID) }
        }
        // Rotación: borrar los descargados que ya no entran (sin empezar a escuchar).
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

    /// Fecha del último refresco completado (para no repetirlo a cada rato al volver a la app).
    var lastRefreshAt: Date?

    /// Refresca los feeds reales EN PARALELO: trae los episodios nuevos sin perder el estado de
    /// los que ya hay, alimenta las listas inteligentes y aplica el auto-descargar. Cada podcast
    /// se procesa Y DESCARGA en cuanto responde SU feed, sin esperar a los demás — antes se
    /// esperaba a que respondieran TODOS antes de bajar nada de ninguno, así que un solo podcast
    /// lento o caído esa noche podía dejar sin descargar TODOS los demás en segundo plano.
    ///
    /// Condicional (ETag/Last-Modified): si un podcast no tiene episodios nuevos, el servidor
    /// responde 304 sin mandar el feed — nos ahorramos bajarlo y parsearlo. Con 25 podcasts y
    /// feeds de hasta varios MB, esto es lo que de verdad decide si el refresco cabe en los ~30
    /// segundos que da iOS en segundo plano, no cuánto tiempo tarda cada descarga individual.
    ///
    /// Se guarda tras CADA podcast que trajo cambios, no al final: si iOS corta la tarea a mitad
    /// (el límite de tiempo en segundo plano), lo ya procesado no se pierde. Antes el `save()`
    /// único al final hacía que un refresco cortado no guardara nada de nada.
    ///
    /// Como mucho `maxConcurrentRefreshes` feeds a la vez (antes se lanzaban TODOS de golpe): con
    /// 25 podcasts reales, eso satura la conexión del móvil y hace más fácil que alguno agote su
    /// timeout de 20s sin haber ni empezado a transferir datos.
    private let maxConcurrentRefreshes = 5

    /// Punto de partida del último refresco (índice sobre el orden actual de `podcasts`), para
    /// rotar por dónde se empieza. Medido: un refresco en segundo plano tarda de media 33s, por
    /// ENCIMA de los ~30s que suele dar iOS — si siempre se empezara por el primero, los últimos
    /// podcasts de la biblioteca casi nunca llegarían a refrescarse en segundo plano. Se guarda en
    /// UserDefaults, no en el JSON de la biblioteca: es un dato de "por dónde voy", no de contenido.
    private static let rotationKey = "unicast.refresh.rotationIndex"

    /// Como mucho un guardado cada `saveThrottle` segundos durante el refresco (antes era uno por
    /// CADA podcast cambiado: hasta 25 reescrituras completas del JSON de 11 MB en la misma
    /// ventana de ~30s). El guardado final de después del bucle sigue garantizado pase lo que
    /// pase, así que lo peor que se pierde si iOS corta a mitad son estos pocos segundos — y la
    /// rotación de arriba ya hace que el siguiente refresco retome justo donde se quedó este.
    private let saveThrottle: TimeInterval = 3

    /// Si ya hay un refresco en marcha, no se lanza otro: dos refrescos a la vez escribirían el
    /// JSON de 11 MB de la biblioteca al mismo tiempo y uno pisaría al otro. Con la automatización
    /// de Atajos ya son CUATRO las vías que pueden disparar un refresco (BGAppRefreshTask,
    /// BGProcessingTask, primer plano, Atajos) — sin este candado, dos de ellas coincidiendo era
    /// cuestión de tiempo.
    private(set) var isRefreshing = false

    @discardableResult
    func refresh(downloads: DownloadManager) async -> RefreshSummary {
        guard !isRefreshing else {
            return RefreshSummary(changed: 0, failed: 0, total: 0, networkSeconds: 0, fastestDetectionSeconds: nil)
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let all = podcasts
        guard !all.isEmpty else {
            return RefreshSummary(changed: 0, failed: 0, total: 0, networkSeconds: 0, fastestDetectionSeconds: nil)
        }
        let start = UserDefaults.standard.integer(forKey: Self.rotationKey) % all.count
        let current = Array(all[start...] + all[..<start])
        var changed = 0
        var failed = 0
        var launched = 0
        var networkSeconds: Double = 0
        var fastestDetectionSeconds: Double?
        var lastSaveAt = Date.distantPast
        await withTaskGroup(of: (UUID, FeedFetchResult, Double).self) { group in
            var queue = current.makeIterator()
            func launchNext() {
                while let podcast = queue.next() {
                    guard let feed = podcast.feedURL else { continue }
                    launched += 1
                    group.addTask { [colorHex = podcast.colorHex,
                                      etag = podcast.feedETag, lastModified = podcast.feedLastModified] in
                        let netStart = Date()
                        let result = await PodcastService.fetchIfChanged(feedURL: feed, colorHex: colorHex,
                                                                           etag: etag, lastModified: lastModified)
                        return (podcast.id, result, Date().timeIntervalSince(netStart))
                    }
                    return
                }
            }
            for _ in 0..<maxConcurrentRefreshes { launchNext() }
            for await (id, result, netTime) in group {
                launchNext()   // uno termina: entra el siguiente de la cola, manteniendo el tope
                networkSeconds += netTime
                if case .failed = result { failed += 1 }
                guard let index = podcasts.firstIndex(where: { $0.id == id }) else { continue }
                guard case .fetched(let fresh, let etag, let lastModified) = result else { continue }
                changed += 1
                let newEpisodes = merge(fresh, into: index)
                for episode in newEpisodes {
                    let detection = Date().timeIntervalSince(episode.publishedAt)
                    if fastestDetectionSeconds == nil || detection < fastestDetectionSeconds! {
                        fastestDetectionSeconds = detection
                    }
                }
                podcasts[index].feedETag = etag
                podcasts[index].feedLastModified = lastModified
                applyAutoDownload(for: id, using: downloads)   // baja nuevos y rota el límite
                if Date().timeIntervalSince(lastSaveAt) >= saveThrottle {
                    save()
                    lastSaveAt = Date()
                }
            }
        }
        // La próxima vez se empieza justo donde se quedó esta — si iOS cortó la tarea a mitad,
        // los que no llegaron a lanzarse son los primeros candidatos del siguiente refresco.
        UserDefaults.standard.set((start + launched) % all.count, forKey: Self.rotationKey)
        lastRefreshAt = Date()
        save()
        return RefreshSummary(changed: changed, failed: failed, total: current.count,
                               networkSeconds: networkSeconds, fastestDetectionSeconds: fastestDetectionSeconds)
    }

    /// Vuelca lo nuevo de `fresh` sobre el podcast ya guardado, sin tocar el estado de lo que ya
    /// había, y repara URLs http:// antiguas en episodios ya existentes (carátula, audio y
    /// capítulos) — iOS las bloquea desde el arreglo del feed de Emilcar/Histocast, pero los
    /// episodios guardados antes de ese arreglo se quedaron con la URL vieja para siempre.
    /// Devuelve los episodios que eran realmente nuevos (para medir cuánto se tarda en detectarlos).
    @discardableResult
    private func merge(_ fresh: Podcast, into index: Int) -> [Episode] {
        var updated = podcasts[index]
        updated.summary = fresh.summary.isEmpty ? updated.summary : fresh.summary
        updated.artworkURL = fresh.artworkURL ?? updated.artworkURL
        let knownTitles = Set(updated.episodes.map(\.title))
        let newEpisodes = fresh.episodes.filter { !knownTitles.contains($0.title) }
        updated.episodes = newEpisodes + updated.episodes   // los nuevos, primero
        let freshByTitle = Dictionary(fresh.episodes.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        for ei in updated.episodes.indices {
            if updated.episodes[ei].chaptersURL == nil, let match = freshByTitle[updated.episodes[ei].title] {
                updated.episodes[ei].chaptersURL = match.chaptersURL
            }
            updated.episodes[ei].artworkURL = updated.episodes[ei].artworkURL?.securedHTTPS
            updated.episodes[ei].audioURL = updated.episodes[ei].audioURL?.securedHTTPS
        }
        podcasts[index] = updated
        addToSmartPlaylists(newEpisodes, from: updated.id)
        return newEpisodes
    }

    /// Refresca solo si el último refresco tiene más de 5 minutos (al volver a la app).
    @discardableResult
    func refreshIfStale(downloads: DownloadManager) async -> RefreshSummary? {
        guard Date().timeIntervalSince(lastRefreshAt ?? .distantPast) > 5 * 60 else { return nil }
        return await refresh(downloads: downloads)
    }

    /// Mete los episodios nuevos en las listas inteligentes que siguen a ese podcast
    /// (la promesa de "los nuevos entran solos"; antes no estaba conectado al refresco).
    private func addToSmartPlaylists(_ episodes: [Episode], from podcastID: UUID) {
        guard !episodes.isEmpty else { return }
        for index in playlists.indices
        where playlists[index].isSmart && playlists[index].sourcePodcastOrder.contains(podcastID) {
            playlists[index].episodeIDs.append(contentsOf: episodes.map(\.id))
        }
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
        save()
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
