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

    init(id: UUID = UUID(), title: String, author: String, summary: String = "",
         feedURL: URL? = nil, colorHex: String, artworkURL: URL? = nil,
         episodes: [Episode] = [], autoDownload: Bool = true,
         downloadLimit: DownloadLimit = .last(5), sortOrder: EpisodeSort = .newest,
         continuousDirection: PlayDirection = .posteriores, notifyNew: Bool = true,
         autoDeleteOnFinish: Bool = true) {
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
    }

    /// Episodios descargados (pestaña "Descargados").
    var downloadedEpisodes: [Episode] { episodes.filter(\.isDownloaded) }

    /// Episodios del feed que NO están descargados (pestaña "Todos").
    var feedEpisodes: [Episode] { episodes.filter { !$0.isDownloaded } }
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

    init(id: UUID = UUID(), title: String, summary: String = "", podcastTitle: String,
         colorHex: String, artworkURL: URL? = nil, audioURL: URL? = nil, duration: TimeInterval, publishedAt: Date,
         isDownloaded: Bool = false, isPlayed: Bool = false, playbackPosition: TimeInterval = 0, chapters: [Chapter] = []) {
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
    var colorHex: String       // color de la imagen del capítulo

    init(id: UUID = UUID(), title: String, start: TimeInterval, colorHex: String) {
        self.id = id
        self.title = title
        self.start = start
        self.colorHex = colorHex
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
