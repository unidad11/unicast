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
    /// Candado del refresco. Vive aquí, y no junto al refresco en `Store+Refresco.swift`, sólo
    /// porque Swift no permite declarar propiedades guardadas en una extensión.
    ///
    /// Con la automatización de Atajos ya son CUATRO las vías que pueden disparar un refresco
    /// (refresco corto, procesamiento, primer plano y Atajos). Sin candado, dos coincidiendo
    /// escribirían a la vez el JSON de 10 MB de la biblioteca y una pisaría a la otra.
    private(set) var isRefreshing = false
    private var refreshStartedAt: Date?

    /// Si iOS SUSPENDE el proceso a mitad de un refresco, el `defer` que suelta el candado no llega
    /// a ejecutarse nunca y `isRefreshing` se queda en true para siempre: todos los despertares
    /// siguientes se irían sin hacer nada, dejando además en el registro un evento que parece un
    /// refresco normal sin novedades. Pasado este tiempo se da por muerto.
    private static let refreshLockTimeout: TimeInterval = 5 * 60

    /// Toma el candado si está libre (o si el anterior se quedó colgado). Devuelve false si ya hay
    /// un refresco de verdad en marcha.
    func beginRefresh() -> Bool {
        let colgado = Date().timeIntervalSince(refreshStartedAt ?? .distantPast) > Self.refreshLockTimeout
        guard !isRefreshing || colgado else { return false }
        isRefreshing = true
        refreshStartedAt = Date()
        return true
    }

    /// Suelta el candado.
    func endRefresh() {
        isRefreshing = false
        refreshStartedAt = nil
    }


    /// Busca un episodio por su id en toda la biblioteca.
    func episode(id: UUID) -> Episode? {
        for podcast in podcasts {
            if let episode = podcast.episodes.first(where: { $0.id == id }) { return episode }
        }
        return nil
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
