import Foundation

/// Un podcast al que el usuario está suscrito.
struct Podcast: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var author: String
    var summary: String        // descripción del autor (resumen de 2 líneas en la cabecera)
    var feedURL: URL?
    var colorHex: String       // color de la portada mientras no haya imagen real
    var artworkURL: URL?
    var episodes: [Episode]

    // Ajustes individuales del podcast (pantalla de ajustes por podcast)
    var autoDownload: Bool
    var downloadLimit: DownloadLimit
    var sortOrder: EpisodeSort
    var continuousDirection: PlayDirection
    var notifyNew: Bool
    var autoDeleteOnFinish: Bool
    var downloadFromDate: Date?   // solo se descargan episodios publicados desde el alta (no el histórico)

    // Cabeceras del último refresco que SÍ trajo cambios (ETag / Last-Modified de la respuesta).
    // Se mandan de vuelta en la siguiente petición para que el servidor pueda responder "sin
    // cambios" (304) sin reenviar el feed entero — así un refresco no vuelve a bajar y parsear
    // los podcasts que ya estaban al día.
    var feedETag: String?
    var feedLastModified: String?

    init(id: UUID = UUID(), title: String, author: String, summary: String = "",
         feedURL: URL? = nil, colorHex: String, artworkURL: URL? = nil,
         episodes: [Episode] = [], autoDownload: Bool = true,
         downloadLimit: DownloadLimit = .last(5), sortOrder: EpisodeSort = .newest,
         continuousDirection: PlayDirection = .posteriores, notifyNew: Bool = true,
         autoDeleteOnFinish: Bool = true, downloadFromDate: Date? = nil,
         feedETag: String? = nil, feedLastModified: String? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.summary = summary
        self.feedURL = feedURL
        self.colorHex = colorHex
        self.artworkURL = artworkURL
        self.episodes = episodes
        self.autoDownload = autoDownload
        self.downloadLimit = downloadLimit
        self.sortOrder = sortOrder
        self.continuousDirection = continuousDirection
        self.notifyNew = notifyNew
        self.autoDeleteOnFinish = autoDeleteOnFinish
        self.downloadFromDate = downloadFromDate
        self.feedETag = feedETag
        self.feedLastModified = feedLastModified
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, author, summary, feedURL, colorHex, artworkURL, episodes
        case autoDownload, downloadLimit, sortOrder, continuousDirection
        case notifyNew, autoDeleteOnFinish, downloadFromDate, feedETag, feedLastModified
    }

    /// Carga tolerante (ver `AppState.init(from:)`): un campo nuevo o un valor corrupto no puede
    /// costar el podcast entero, y menos aún la biblioteca completa.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Ver `Episode.init(from:)`: el id no puede inventarse. El de un podcast enlaza además con
        // las listas inteligentes (`sourcePodcastOrder`).
        id = try c.decode(UUID.self, forKey: .id)
        title = c.lenient(.title, or: "")
        author = c.lenient(.author, or: "")
        summary = c.lenient(.summary, or: "")
        feedURL = c.lenientOptional(URL.self, .feedURL)
        colorHex = c.lenient(.colorHex, or: "6B5CE7")
        artworkURL = c.lenientOptional(URL.self, .artworkURL)
        episodes = c.lenientArray(Episode.self, .episodes)
        autoDownload = c.lenient(.autoDownload, or: true)
        downloadLimit = c.lenient(.downloadLimit, or: DownloadLimit.last(5))
        sortOrder = c.lenient(.sortOrder, or: EpisodeSort.newest)
        continuousDirection = c.lenient(.continuousDirection, or: PlayDirection.posteriores)
        notifyNew = c.lenient(.notifyNew, or: true)
        autoDeleteOnFinish = c.lenient(.autoDeleteOnFinish, or: true)
        downloadFromDate = c.lenientOptional(Date.self, .downloadFromDate)
        feedETag = c.lenientOptional(String.self, .feedETag)
        feedLastModified = c.lenientOptional(String.self, .feedLastModified)
    }

    /// Episodios descargados (pestaña "Descargados").
    var downloadedEpisodes: [Episode] { episodes.filter(\.isDownloaded) }

    /// Todos los episodios del feed, descargados o no (pestaña "Todos"). Antes escondía los que ya
    /// estaban descargados, así que no había forma de ver en una sola lista qué tienes y qué no.
    var feedEpisodes: [Episode] { episodes }
}

/// Un episodio concreto de un podcast.
struct Episode: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var summary: String
    var podcastTitle: String
    var colorHex: String           // color heredado del podcast (para la mini-portada)
    var artworkURL: URL?           // carátula del podcast (para el Now Playing / isla)
    var audioURL: URL?
    var duration: TimeInterval     // duración total en segundos
    var publishedAt: Date
    var isDownloaded: Bool
    var isPlayed: Bool              // ya escuchado: no reaparece en "Todos"
    var playbackPosition: TimeInterval  // dónde se quedó, para retomar (puntos 11 y 12)
    var chapters: [Chapter]
    var chaptersURL: URL?    // capítulos en un JSON aparte (formato Podcasting 2.0), si el feed los trae así
    /// Lo bajó el usuario a mano desde "Todos", no el auto-descargar. La rotación del límite de
    /// descargas NO puede tocar estos: si alguien se baja un capítulo viejo a propósito para el
    /// avión, el siguiente refresco no se lo puede borrar por "no entrar en los 5 últimos".
    var manuallyDownloaded: Bool
    /// Cuántos bytes dice el feed que ocupa el audio (atributo `length` del `<enclosure>`).
    ///
    /// No es decoración: es el único dato con el que se puede responder a iOS cuánto va a pesar una
    /// descarga. Apple insiste en el propio SDK en que el sistema usa esa cifra "para optimizar la
    /// planificación de las tareas", y las descargas nocturnas son justo las que iOS planifica a su
    /// antojo. Sin esta cifra, para el planificador son transferencias de tamaño DESCONOCIDO, que es
    /// el peor caso posible. Venía gratis en el feed y se estaba tirando.
    var audioBytes: Int64?
    /// Cuántas veces seguidas ha fallado la descarga de este episodio, y cuándo fue la última.
    ///
    /// Sin esto, un episodio cuya URL está muerta (404, servidor que ya no existe) se volvía a
    /// intentar en CADA refresco: unas quince veces al día, para siempre, gastando datos y la
    /// ventana de segundo plano que hace falta para los episodios que sí existen.
    var downloadFailures: Int
    var lastDownloadFailureAt: Date?
    /// El `<guid>` del feed: el identificador que el autor le da al episodio y que no cambia
    /// aunque corrija el título. Hasta ahora la identidad era el TÍTULO, y eso tenía dos fallos
    /// silenciosos: si el autor corregía una errata, el episodio entraba otra vez como nuevo y se
    /// volvía a descargar entero; y si dos episodios compartían título (un "Bonus", un "Especial"),
    /// el segundo se descartaba para siempre sin decir nada.
    var guid: String?

    init(id: UUID = UUID(), title: String, summary: String = "", podcastTitle: String,
         colorHex: String, artworkURL: URL? = nil, audioURL: URL? = nil, duration: TimeInterval, publishedAt: Date,
         isDownloaded: Bool = false, isPlayed: Bool = false, playbackPosition: TimeInterval = 0, chapters: [Chapter] = [],
         chaptersURL: URL? = nil, manuallyDownloaded: Bool = false, audioBytes: Int64? = nil,
         downloadFailures: Int = 0, lastDownloadFailureAt: Date? = nil, guid: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.podcastTitle = podcastTitle
        self.colorHex = colorHex
        self.artworkURL = artworkURL
        self.audioURL = audioURL
        self.duration = duration
        self.publishedAt = publishedAt
        self.isDownloaded = isDownloaded
        self.isPlayed = isPlayed
        self.playbackPosition = playbackPosition
        self.chapters = chapters
        self.chaptersURL = chaptersURL
        self.manuallyDownloaded = manuallyDownloaded
        self.audioBytes = audioBytes
        self.downloadFailures = downloadFailures
        self.lastDownloadFailureAt = lastDownloadFailureAt
        self.guid = guid
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, podcastTitle, colorHex, artworkURL, audioURL
        case duration, publishedAt, isDownloaded, isPlayed, playbackPosition
        case chapters, chaptersURL, manuallyDownloaded, audioBytes
        case downloadFailures, lastDownloadFailureAt, guid
    }

    /// Carga tolerante (ver `AppState.init(from:)`). `publishedAt` cae a `distantPast` a propósito
    /// si viene ilegible: así el episodio queda FUERA de la ventana de auto-descarga en vez de
    /// colarse dentro y provocar descargas que nadie pidió.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // El id es lo ÚNICO que no puede caer a un valor por defecto. El nombre del mp3 en disco
        // es ese id: inventarle uno nuevo dejaba el audio huérfano (y la limpieza lo borraba),
        // marcaba el episodio como descargado sin estarlo y forzaba bajarlo otra vez entero. Si no
        // se puede leer, este episodio se descarta —`lenientArray` lo salta sin romper el resto—
        // en vez de resucitarlo con una identidad falsa.
        id = try c.decode(UUID.self, forKey: .id)
        title = c.lenient(.title, or: "")
        summary = c.lenient(.summary, or: "")
        podcastTitle = c.lenient(.podcastTitle, or: "")
        colorHex = c.lenient(.colorHex, or: "6B5CE7")
        artworkURL = c.lenientOptional(URL.self, .artworkURL)
        audioURL = c.lenientOptional(URL.self, .audioURL)
        duration = c.lenient(.duration, or: TimeInterval(0))
        publishedAt = c.lenient(.publishedAt, or: Date.distantPast)
        isDownloaded = c.lenient(.isDownloaded, or: false)
        isPlayed = c.lenient(.isPlayed, or: false)
        playbackPosition = c.lenient(.playbackPosition, or: TimeInterval(0))
        chapters = c.lenientArray(Chapter.self, .chapters)
        chaptersURL = c.lenientOptional(URL.self, .chaptersURL)
        manuallyDownloaded = c.lenient(.manuallyDownloaded, or: false)
        audioBytes = c.lenientOptional(Int64.self, .audioBytes)
        downloadFailures = c.lenient(.downloadFailures, or: 0)
        lastDownloadFailureAt = c.lenientOptional(Date.self, .lastDownloadFailureAt)
        guid = c.lenientOptional(String.self, .guid)
    }

    /// Tiempo que falta para terminar, en segundos.
    var remaining: TimeInterval { max(0, duration - playbackPosition) }

    /// Fracción reproducida (0 a 1), para la barra de progreso.
    var progress: Double { duration > 0 ? min(1, playbackPosition / duration) : 0 }
}

/// Un capítulo dentro de un episodio (los que marca el autor), con su imagen.
struct Chapter: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var start: TimeInterval    // segundo en el que empieza
    var colorHex: String       // color de respaldo si el autor no puso imagen
    var imageURL: URL?         // imagen real del capítulo, si el autor la incluyó en el feed
    var linkURL: URL?          // enlace del capítulo (p.ej. al producto del que habla), si lo trae

    init(id: UUID = UUID(), title: String, start: TimeInterval, colorHex: String, imageURL: URL? = nil, linkURL: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.colorHex = colorHex
        self.imageURL = imageURL
        self.linkURL = linkURL
    }
}

/// Una lista de reproducción. Puede ser manual o inteligente.
///
/// La inteligente "copia" a una manual: usa los mismos podcasts de origen y, cuando llegan
/// episodios nuevos de esos podcasts, entran solos. El orden que el usuario fijó a mano
/// (`sourcePodcastOrder`) define la prioridad POR PODCAST.
struct Playlist: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var isSmart: Bool
    var sourcePodcastOrder: [UUID]   // orden por podcast (prioridad en la inteligente)
    var episodeIDs: [UUID]           // orden manual de los episodios

    init(id: UUID = UUID(), name: String, isSmart: Bool = false,
         sourcePodcastOrder: [UUID] = [], episodeIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.sourcePodcastOrder = sourcePodcastOrder
        self.episodeIDs = episodeIDs
    }
}

// MARK: - Opciones

/// Cuántos episodios se bajan automáticamente.
enum DownloadLimit: Hashable, Codable {
    case all
    case last(Int)

    var label: String {
        switch self {
        case .all: "Todos"
        case .last(let n): "Los \(n) últimos"
        }
    }
}

/// Orden de la lista de episodios.
enum EpisodeSort: String, CaseIterable, Codable {
    case newest, oldest
    var label: String { self == .newest ? "Más recientes" : "Más antiguos" }
}

/// Sentido de la reproducción continua (más técnico que "nuevo/viejo").
enum PlayDirection: String, CaseIterable, Codable {
    case anteriores, posteriores
    var label: String { self == .anteriores ? "Anteriores" : "Posteriores" }
}

/// Forma de ver la biblioteca (punto 20 + vista de mazos estilo Brink).
enum LibraryLayout: String, CaseIterable, Codable {
    case grid, decks, list
    var label: String {
        switch self {
        case .grid: "Cuadrícula"
        case .decks: "Mazos"
        case .list: "Lista"
        }
    }
}

/// Pestañas dentro de un podcast (estilo Overcast, sin "Escuchados").
enum PodcastTab: String, CaseIterable {
    case downloaded, all
    var label: String { self == .downloaded ? "Descargados" : "Todos" }
}
