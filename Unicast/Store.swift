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

/// Un episodio que DEBERÍA estar descargado y no lo está, junto al podcast al que pertenece.
/// Con nombre propio (y no una tupla) porque la pantalla de diagnóstico lo recorre con `ForEach`,
/// y `ForEach` necesita un `id`: sobre una tupla no se puede escribir un key path.
struct PendingDownload: Identifiable {
    let episode: Episode
    let podcastID: UUID
    var id: UUID { episode.id }
}

/// @MainActor de verdad, no de boquilla.
///
/// Antes esto no estaba, y los `@MainActor` que hay en los sitios que LLAMAN a `refresh` no
/// servían de nada: desde Swift 5.7 una función `async` no aislada nunca hereda el actor de quien
/// la llama, así que el refresco corría en un hilo de fondo. Comprobado ejecutándolo, no leyéndolo.
///
/// Consecuencia real, y es seguramente la explicación de las descargas que "se bajaban pero no se
/// quedaban marcadas": mientras el refresco escribía `podcasts` desde un hilo de fondo, el hilo
/// principal escribía la marca de descargado de un episodio recién bajado. `merge` hace
/// copia-modifica-devuelve, así que el refresco machacaba esa marca y acto seguido la guardaba en
/// disco. El episodio quedaba en el móvil pero figurando como no descargado, y el siguiente
/// refresco lo volvía a bajar entero.
@MainActor
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

    /// La biblioteca que hay cargada es la de ejemplo, no la del usuario (no había archivo o no
    /// se pudo leer). Mientras esté en true NO se toca el disco: el audio descargado que haya ahí
    /// pertenece a la biblioteca de verdad, y borrarlo por "huérfano" fue justo la forma en la que
    /// un solo fallo de lectura se llevaba por delante todas las descargas.
    private(set) var isSampleLibrary = false

    /// No escribir en disco bajo ningún concepto. Se enciende cuando la biblioteca de verdad está
    /// en disco pero no se ha podido leer: guardar en ese estado sería sustituirla por nada.
    private(set) var savingBlocked = false

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
            podcasts[pi].episodes[ei].manuallyDownloaded = false
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
        guard let pi = podcasts.firstIndex(where: { $0.episodes.contains { $0.id == episodeID } }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        // "Borrar al terminar" es un ajuste POR PODCAST que estaba en la pantalla de ajustes desde
        // el principio y no lo consultaba nadie: el audio se borraba siempre, lo tuvieras puesto o
        // no. Si está apagado, el episodio se marca escuchado pero el archivo se queda.
        if podcasts[pi].autoDeleteOnFinish {
            DownloadManager.deleteFile(for: episodeID)
            podcasts[pi].episodes[ei].isDownloaded = false
            podcasts[pi].episodes[ei].manuallyDownloaded = false
        }
        podcasts[pi].episodes[ei].isPlayed = true   // escuchado: desaparece de Todos
        podcasts[pi].episodes[ei].playbackPosition = 0
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
        podcasts[pi].episodes[ei].downloadFailures = 0   // salió bien: se olvida lo anterior
        podcasts[pi].episodes[ei].lastDownloadFailureAt = nil
        save()
    }

    /// Devuelve un episodio a "no escuchado", para que la auto-descarga vuelva a ocuparse de él.
    ///
    /// Hasta ahora `isPlayed` era un camino de ida sin vuelta: lo ponen a true tanto terminar un
    /// episodio como descartarlo deslizando, y NADA en toda la app lo devolvía a false. Un capítulo
    /// descartado por error quedaba excluido de la descarga automática para siempre, sin ninguna
    /// forma de deshacerlo.
    func markUnplayed(_ episodeID: UUID, in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].isPlayed = false
        podcasts[pi].episodes[ei].downloadFailures = 0   // que se reintente ya, sin esperas
        podcasts[pi].episodes[ei].lastDownloadFailureAt = nil
        save()
    }

    /// Apunta que una descarga ha fallado, para no reintentarla sin parar.
    func markDownloadFailed(_ episodeID: UUID) {
        for pi in podcasts.indices {
            if let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) {
                podcasts[pi].episodes[ei].downloadFailures += 1
                podcasts[pi].episodes[ei].lastDownloadFailureAt = Date()
                save()
                return
            }
        }
    }

    /// ¿Toca esperar antes de volver a intentar este episodio? La espera se dobla con cada fallo
    /// (1 h, 2 h, 4 h...) y se queda en 24 h como mucho. Así una URL muerta se intenta una vez al
    /// día en vez de quince, pero si el servidor vuelve, el episodio se recupera solo.
    private func waitingAfterFailure(_ episode: Episode) -> Bool {
        guard episode.downloadFailures > 0, let last = episode.lastDownloadFailureAt else { return false }
        let hours = min(pow(2.0, Double(episode.downloadFailures - 1)), 24)
        return Date().timeIntervalSince(last) < hours * 3600
    }

    /// Apunta que esta descarga la ha pedido el usuario a mano (botón de descargar en "Todos").
    /// Se marca AL PULSAR, no al terminar: si la descarga acaba de madrugada con la app cerrada,
    /// la marca ya está guardada y la rotación del límite no se lo lleva por delante.
    func markManuallyDownloaded(_ episodeID: UUID, in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].manuallyDownloaded = true
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
        // Con la biblioteca de ejemplo cargada no hay nada real que repasar: lo único que se
        // conseguiría es ponerse a bajar los episodios de mentira de `SampleData`.
        guard !isSampleLibrary else { return 0 }
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
        // Se rebajan TODOS los que se quedaron sin audio, no solo los empezados. Antes solo se
        // recuperaban los de `playbackPosition > 0` y el resto quedaba a la espera del refresco —
        // que nunca los recogía si ya habían salido de la ventana de auto-descarga: eran capítulos
        // marcados "Descargado" que en el móvil no existían y nadie volvía a bajar jamás.
        for item in missing where !item.episode.isPlayed {
            // Uno que el usuario bajó a mano se recupera con la red que haya; los automáticos
            // respetan "Descargar solo con WiFi".
            let cellular = item.episode.manuallyDownloaded || !wifiOnlyDownloads
            downloads.download(item.episode, allowsCellular: cellular) { [weak self] in
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
            // Si lo que está sonando era de este podcast, hay que soltarlo: su audio se acaba de
            // borrar y el reproductor se quedaría apuntando a un archivo que ya no existe.
            if let playing = nowPlaying, podcast.episodes.contains(where: { $0.id == playing.id }) {
                nowPlaying = nil
                isPlaying = false
                isPlayerPresented = false
            }
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
        // El límite elegido en Ajustes → "Guardar por defecto". Estaba ahí desde el principio y no
        // se aplicaba en ningún sitio: todo podcast nuevo se quedaba con los 5 de fábrica.
        fresh.downloadLimit = defaultDownloadLimit
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
            podcasts[pi].downloadFromDate = effectiveDownloadFrom(podcasts[pi])
        }
        let podcast = podcasts[pi]
        let keep = autoDownloadWindow(for: podcast)
        let keepIDs = Set(keep.map(\.id))
        // También se pregunta al disco, no solo al flag en memoria: si `onFinished` no llegó a
        // marcar una descarga de la noche (el caso que arregla el bug de arriba, en versiones
        // futuras si volviera a colarse uno parecido), sin este chequeo se re-descargaría el
        // mismo mp3 entero en cada refresco, varias veces al día.
        for ep in keep
        where !ep.isDownloaded && !ep.isPlayed && !DownloadManager.isDownloaded(ep.id) && !waitingAfterFailure(ep) {
            downloads.download(ep, allowsCellular: !wifiOnlyDownloads, notify: podcast.notifyNew) { [weak self] in
                self?.markDownloaded(ep.id, in: podcastID)
            }
        }
        // Rotación: borrar los descargados que ya no entran (sin empezar a escuchar). Los que el
        // usuario se bajó A MANO quedan fuera de la rotación: los eligió él, los borra él.
        for ep in podcast.episodes
        where ep.isDownloaded && !keepIDs.contains(ep.id) && ep.playbackPosition == 0 && !ep.manuallyDownloaded {
            removeFromDownloads(ep.id, in: podcastID)
        }
    }

    /// Qué episodios DEBERÍAN estar descargados de un podcast: los publicados desde el alta
    /// (nunca el histórico anterior), los más recientes primero, recortados al límite del podcast.
    private func autoDownloadWindow(for podcast: Podcast) -> [Episode] {
        let from = effectiveDownloadFrom(podcast)
        let eligible = podcast.episodes.filter { $0.publishedAt >= from }.sorted { $0.publishedAt > $1.publishedAt }
        switch podcast.downloadLimit {
        case .all: return eligible
        case .last(let n): return Array(eligible.prefix(n))
        }
    }

    /// Fecha de corte efectiva de un podcast. Si es de antes de que existiera `downloadFromDate`,
    /// se comporta como si fuera la del 4º episodio más reciente — el mismo criterio que usa la
    /// migración de `applyAutoDownload`, para que consultar y actuar den siempre lo mismo.
    private func effectiveDownloadFrom(_ podcast: Podcast) -> Date {
        if let date = podcast.downloadFromDate { return date }
        let sorted = podcast.episodes.sorted { $0.publishedAt > $1.publishedAt }
        if sorted.count >= 4 { return sorted[3].publishedAt }
        // Sin episodios el corte NO puede ser "ahora": si el podcast acaba de estrenarse y su
        // primer capítulo trae una fecha anterior al momento exacto en que le diste a seguir
        // —cosa normal—, ese capítulo quedaría fuera para siempre. Sin histórico que proteger,
        // el pasado es seguro: el límite de descargas ya acota cuántos se bajan.
        return sorted.last?.publishedAt ?? .distantPast
    }

    /// Todo lo que debería estar descargado en la biblioteca y todavía no está. Es la lista que
    /// enseña la pantalla de diagnóstico, y lo que baja su botón.
    func pendingDownloads() -> [PendingDownload] {
        var pending: [PendingDownload] = []
        for podcast in podcasts where podcast.autoDownload {
            for ep in autoDownloadWindow(for: podcast)
            where !ep.isPlayed && !DownloadManager.isDownloaded(ep.id) {
                pending.append(PendingDownload(episode: ep, podcastID: podcast.id))
            }
        }
        return pending
    }

    /// Baja ya todo lo que falte (botón "Descargar lo que falta" del diagnóstico). Lo pide el
    /// usuario, así que NO se aplica "Descargar solo con WiFi".
    func downloadPending(using downloads: DownloadManager) {
        for item in pendingDownloads() {
            downloads.download(item.episode) { [weak self] in
                self?.markDownloaded(item.episode.id, in: item.podcastID)
            }
        }
    }

    /// Quita un episodio de Descargados (borra el audio) sin marcarlo escuchado — para la rotación.
    func removeFromDownloads(_ episodeID: UUID, in podcastID: UUID) {
        DownloadManager.deleteFile(for: episodeID)
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].isDownloaded = false
        podcasts[pi].episodes[ei].manuallyDownloaded = false
        save()
    }

    /// Borra TODAS las descargas de un podcast (el audio), dejando los episodios en "Todos".
    func clearDownloads(for podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        for ep in podcasts[pi].episodes where ep.isDownloaded { DownloadManager.deleteFile(for: ep.id) }
        for ei in podcasts[pi].episodes.indices {
            podcasts[pi].episodes[ei].isDownloaded = false
            podcasts[pi].episodes[ei].manuallyDownloaded = false
        }
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

    /// Cuándo empezó el refresco que tiene el candado. Sin esto, si iOS SUSPENDE el proceso a
    /// mitad de un refresco el `defer` nunca corre, `isRefreshing` se queda en true para siempre y
    /// todos los despertares siguientes se van sin hacer nada — dejando además en el registro un
    /// evento que parece un refresco normal sin novedades. Pasado este tiempo se da por muerto.
    private var refreshStartedAt: Date?
    private let refreshLockTimeout: TimeInterval = 5 * 60

    @discardableResult
    func refresh(downloads: DownloadManager) async -> RefreshSummary {
        let lockIsStale = Date().timeIntervalSince(refreshStartedAt ?? .distantPast) > refreshLockTimeout
        guard !isRefreshing || lockIsStale else {
            return RefreshSummary(changed: 0, failed: 0, total: 0, networkSeconds: 0, fastestDetectionSeconds: nil)
        }
        isRefreshing = true
        refreshStartedAt = Date()
        defer { isRefreshing = false; refreshStartedAt = nil }
        let all = podcasts
        guard !all.isEmpty else {
            return RefreshSummary(changed: 0, failed: 0, total: 0, networkSeconds: 0, fastestDetectionSeconds: nil)
        }
        let start = UserDefaults.standard.integer(forKey: Self.rotationKey) % all.count
        let current = Array(all[start...] + all[..<start])
        var changed = 0
        var failed = 0
        var processed = 0
        var networkSeconds: Double = 0
        var fastestDetectionSeconds: Double?
        var lastSaveAt = Date.distantPast
        await withTaskGroup(of: (UUID, FeedFetchResult, Double).self) { group in
            var queue = current.makeIterator()
            func launchNext() {
                while let podcast = queue.next() {
                    guard let feed = podcast.feedURL else { continue }
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
                processed += 1
                networkSeconds += netTime
                // El punto de partida del siguiente refresco se guarda AQUÍ, según lo que de verdad
                // se ha terminado de procesar, y no al final del bucle. Dos motivos: si iOS corta
                // la tarea a mitad, la línea del final no llega a ejecutarse nunca; y la cuenta
                // anterior sumaba los podcasts LANZADOS, que al drenarse siempre el grupo entero
                // acababan siendo todos — `(start + total) % total` devuelve el mismo índice, así
                // que la rotación llevaba desde que se escribió sin rotar absolutamente nada.
                UserDefaults.standard.set((start + processed) % all.count, forKey: Self.rotationKey)
                if case .failed = result { failed += 1 }
                guard let index = podcasts.firstIndex(where: { $0.id == id }) else { continue }
                if case .fetched(let fresh, let etag, let lastModified) = result {
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
                }
                // Baja lo que falte y rota el límite SIEMPRE, traiga o no novedades el feed. Antes
                // esto vivía dentro del `case .fetched` y ahí estaba la fuga: con el refresco
                // condicional (ETag/304) la inmensa mayoría de los podcasts responden "sin
                // cambios", así que una descarga que había fallado no se reintentaba NUNCA — se
                // quedaba esperando a que ese podcast publicara un capítulo nuevo.
                applyAutoDownload(for: id, using: downloads)
                if Date().timeIntervalSince(lastSaveAt) >= saveThrottle {
                    save()
                    lastSaveAt = Date()
                }
            }
        }
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

        // Índices de lo que ya está guardado: por identificador del feed (lo estable) y por título
        // (el respaldo de siempre, para los feeds que no traen <guid>).
        var indexByGuid: [String: Int] = [:]
        var indexByTitle: [String: Int] = [:]
        for (position, episode) in updated.episodes.enumerated() {
            if let guid = episode.guid, indexByGuid[guid] == nil { indexByGuid[guid] = position }
            if indexByTitle[episode.title] == nil { indexByTitle[episode.title] = position }
        }

        var newEpisodes: [Episode] = []
        for incoming in fresh.episodes {
            // 1) Lo conocemos por su identificador: es el mismo episodio aunque le hayan cambiado
            //    el título. Antes esto entraba como capítulo nuevo y se volvía a descargar entero.
            if let guid = incoming.guid, let position = indexByGuid[guid] {
                adopt(incoming, into: &updated.episodes[position])
                continue
            }
            // 2) Traspaso: lo guardado es de antes de que se leyeran los <guid>, así que todavía no
            //    tiene ninguno. Si el título coincide es el mismo episodio: se le adopta el
            //    identificador y a partir de ahora ya no depende del título para nada.
            if let position = indexByTitle[incoming.title], updated.episodes[position].guid == nil {
                updated.episodes[position].guid = incoming.guid
                if let guid = incoming.guid { indexByGuid[guid] = position }
                adopt(incoming, into: &updated.episodes[position])
                continue
            }
            // 3) El feed no da identificador y el título ya lo habíamos visto: se da por conocido.
            if incoming.guid == nil, indexByTitle[incoming.title] != nil { continue }
            // 4) Nuevo de verdad. Ojo: aquí entra también un episodio cuyo título coincide con otro
            //    que YA tiene un identificador distinto — dos capítulos llamados igual ("Bonus",
            //    "Especial"). Antes el segundo se descartaba en silencio y no se bajaba jamás.
            newEpisodes.append(incoming)
        }

        updated.episodes = newEpisodes + updated.episodes   // los nuevos, primero
        for ei in updated.episodes.indices {
            updated.episodes[ei].artworkURL = updated.episodes[ei].artworkURL?.securedHTTPS
            updated.episodes[ei].audioURL = updated.episodes[ei].audioURL?.securedHTTPS
        }
        podcasts[index] = updated
        addToSmartPlaylists(newEpisodes, from: updated.id)
        return newEpisodes
    }

    /// Refresca de un episodio ya guardado lo que el feed puede cambiar sin que deje de ser el
    /// mismo episodio. NUNCA toca el estado del usuario: ni descargado, ni escuchado, ni la
    /// posición de reproducción.
    private func adopt(_ incoming: Episode, into stored: inout Episode) {
        if !incoming.title.isEmpty { stored.title = incoming.title }
        if stored.chaptersURL == nil { stored.chaptersURL = incoming.chaptersURL }
        if stored.audioBytes == nil { stored.audioBytes = incoming.audioBytes }
        if stored.audioURL == nil { stored.audioURL = incoming.audioURL }
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
            playlists[index].episodeIDs.insert(contentsOf: episodes.map(\.id),
                                               at: insertionPoint(in: playlists[index], for: podcastID))
        }
    }

    /// Dónde colocar un episodio nuevo dentro de una lista inteligente.
    ///
    /// La promesa era que el orden en que el usuario colocó los podcasts (`sourcePodcastOrder`)
    /// decide la prioridad, y que un episodio nuevo entra en el sitio de SU podcast. En realidad
    /// ese orden solo se usaba para saber qué podcasts pertenecían a la lista, y todo lo nuevo se
    /// añadía al final: el campo podía haber sido un conjunto y nada habría cambiado.
    ///
    /// Aquí se busca el primer episodio de la lista cuyo podcast vaya DESPUÉS que este en el orden,
    /// y se coloca justo delante. Si no hay ninguno, va al final.
    private func insertionPoint(in playlist: Playlist, for podcastID: UUID) -> Int {
        guard let rank = playlist.sourcePodcastOrder.firstIndex(of: podcastID) else {
            return playlist.episodeIDs.count
        }
        for (position, episodeID) in playlist.episodeIDs.enumerated() {
            guard let owner = podcasts.first(where: { $0.episodes.contains { $0.id == episodeID } }),
                  let otherRank = playlist.sourcePodcastOrder.firstIndex(of: owner.id) else { continue }
            if otherRank > rank { return position }
        }
        return playlist.episodeIDs.count
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
        switch Persistence.load() {
        case .loaded(let state):
            store.apply(state)
        case .fresh:
            // Instalación nueva (o archivo ilegible ya apartado a un lado): datos de ejemplo.
            store.isSampleLibrary = true
            store.podcasts = SampleData.podcasts
            store.playlists = SampleData.playlists
            store.nowPlaying = SampleData.nowPlaying
            store.save()
        case .unreadable:
            // El archivo está ahí pero no se ha podido leer AHORA. Se arranca en blanco y con el
            // guardado bloqueado: ni datos de ejemplo ni `save()`, porque cualquiera de las dos
            // cosas se llevaría por delante los 25 podcasts del usuario por un fallo pasajero.
            store.isSampleLibrary = true
            store.savingBlocked = true
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
    func save() {
        guard !savingBlocked else { return }
        Persistence.save(snapshot())
    }
}
