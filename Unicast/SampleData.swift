import Foundation

/// Datos de ejemplo para poder ver la interfaz mientras no hay feeds reales conectados.
/// Se sustituirán por los podcasts reales cuando enchufemos el motor de RSS.
enum SampleData {

    static let podcasts: [Podcast] = makePodcasts()
    static let playlists: [Playlist] = makePlaylists(from: podcasts)

    /// Episodio que aparece "sonando ahora" al abrir la app.
    static var nowPlaying: Episode? {
        podcasts.first?.episodes.first
    }

    /// Catálogo de ejemplo para la pantalla de Buscar (algunos ya están en la biblioteca).
    static let searchCatalog: [Podcast] = [
        Podcast(title: "No es asunto vuestro", author: "NEAV", colorHex: "F2E14B"),
        Podcast(title: "Hard Fork", author: "The New York Times", colorHex: "C2E04B"),
        Podcast(title: "Monos estocásticos", author: "Ortiz y Durán", colorHex: "5B5BD6"),
        Podcast(title: "Spicy4tuna", author: "Boluda, Bonilla y Varas", colorHex: "E8743B"),
        Podcast(title: "mixx.io diario", author: "Álex Barredo", colorHex: "2D6CDF"),
        Podcast(title: "The Vergecast", author: "The Verge", colorHex: "C94F86"),
        Podcast(title: "Acquired", author: "Ben Gilbert y David Rosenthal", colorHex: "159E78"),
        Podcast(title: "Nadie Sabe Nada", author: "Cadena SER", colorHex: "E24B4A")
    ]

    // MARK: - Construcción

    private static func makePodcasts() -> [Podcast] {
        let neav = Podcast(
            title: "No es asunto vuestro",
            author: "NEAV",
            summary: "Josep Maria Poblet y el equipo de NEAV diseccionan cada semana la actualidad de la tecnología y los negocios, sin pelos en la lengua.",
            colorHex: "F2E14B",
            episodes: [
                Episode(title: "442. Descubriendo Google Discover", summary: "Cómo cambia la búsqueda de Google con la IA generativa.", podcastTitle: "No es asunto vuestro", colorHex: "F2E14B", audioURL: URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"), duration: 1980, publishedAt: daysAgo(0), isDownloaded: true, playbackPosition: 1260,
                        chapters: [
                            Chapter(title: "Intro", start: 0, colorHex: "2D6CDF"),
                            Chapter(title: "La era post-buscador", start: 150, colorHex: "E8743B"),
                            Chapter(title: "Qué cambia para los medios", start: 850, colorHex: "159E78"),
                            Chapter(title: "Monetizar la IA", start: 1320, colorHex: "C94F86")
                        ]),
                Episode(title: "441. La estafa de las renovables", summary: "Análisis sin filtros del sector energético.", podcastTitle: "No es asunto vuestro", colorHex: "F2E14B", duration: 4320, publishedAt: daysAgo(1), isDownloaded: true),
                Episode(title: "440. De emprendedor a empresario", summary: "Los errores que casi todos cometen al crecer.", podcastTitle: "No es asunto vuestro", colorHex: "F2E14B", duration: 3480, publishedAt: daysAgo(2), isDownloaded: true),
                Episode(title: "439. Bingo WWDC 2026", summary: "Predicciones y apuestas para la keynote de Apple.", podcastTitle: "No es asunto vuestro", colorHex: "F2E14B", duration: 2700, publishedAt: daysAgo(3))
            ])

        let hardFork = Podcast(
            title: "Hard Fork",
            author: "The New York Times",
            summary: "Kevin Roose y Casey Newton charlan sobre la tecnología que está cambiando el mundo y por qué deberías (o no) preocuparte.",
            colorHex: "C2E04B",
            episodes: [
                Episode(title: "La era post-buscador", summary: "El futuro de la búsqueda en internet.", podcastTitle: "Hard Fork", colorHex: "C2E04B", duration: 3720, publishedAt: daysAgo(1)),
                Episode(title: "Agentes por todas partes", summary: "Qué son los agentes de IA y para qué sirven.", podcastTitle: "Hard Fork", colorHex: "C2E04B", duration: 3960, publishedAt: daysAgo(4))
            ])

        let dailyBlast = Podcast(
            title: "The Daily Blast",
            author: "The New Republic",
            summary: "El pulso diario de la política estadounidense en menos de una hora.",
            colorHex: "E24B4A",
            episodes: [
                Episode(title: "Trump hits record low in polls", summary: "Lo último de las encuestas.", podcastTitle: "The Daily Blast", colorHex: "E24B4A", duration: 2880, publishedAt: daysAgo(0))
            ])

        let waveform = Podcast(
            title: "Waveform",
            author: "MKBHD",
            summary: "El podcast de tecnología de Marques Brownlee y su equipo: gadgets, reseñas y debates.",
            colorHex: "8C2F26",
            episodes: [
                Episode(title: "El mejor móvil del año", summary: "Comparativa de buques insignia.", podcastTitle: "Waveform", colorHex: "8C2F26", duration: 4500, publishedAt: daysAgo(5))
            ])

        let spicy = Podcast(
            title: "Spicy4tuna",
            author: "Boluda, Bonilla y Varas",
            summary: "Tres emprendedores cuentan sin filtros sus aciertos y meteduras de pata montando negocios.",
            colorHex: "E8743B",
            episodes: [
                Episode(title: "Cómo pasar de emprendedor a empresario", summary: "Escalar sin morir en el intento.", podcastTitle: "Spicy4tuna", colorHex: "E8743B", duration: 2880, publishedAt: daysAgo(2)),
                Episode(title: "La estafa de las renovables", summary: "Debate encendido.", podcastTitle: "Spicy4tuna", colorHex: "E8743B", duration: 2940, publishedAt: daysAgo(6))
            ])

        let monos = Podcast(
            title: "Monos estocásticos",
            author: "Ortiz y Durán",
            summary: "Inteligencia artificial explicada con calma y criterio, una semana cada vez.",
            colorHex: "5B5BD6",
            episodes: [
                Episode(title: "Quién manda en los chips", summary: "La guerra de los semiconductores.", podcastTitle: "Monos estocásticos", colorHex: "5B5BD6", duration: 4500, publishedAt: daysAgo(3))
            ])

        return [neav, hardFork, dailyBlast, waveform, spicy, monos]
    }

    private static func makePlaylists(from podcasts: [Podcast]) -> [Playlist] {
        // Una lista inteligente "Mañanas" que copia varios podcasts.
        let sources = Array(podcasts.prefix(3))
        let smartEpisodes = sources.compactMap { $0.episodes.first?.id }

        let mananas = Playlist(
            name: "Mañanas",
            isSmart: true,
            sourcePodcastOrder: sources.map(\.id),
            episodeIDs: smartEpisodes
        )
        let gimnasio = Playlist(
            name: "Para el gimnasio",
            episodeIDs: podcasts.flatMap { $0.episodes.prefix(1).map(\.id) }
        )
        let tech = Playlist(
            name: "Tecnología al día",
            isSmart: true,
            sourcePodcastOrder: [podcasts[1].id, podcasts[5].id],
            episodeIDs: [podcasts[1].episodes.first?.id, podcasts[5].episodes.first?.id].compactMap { $0 }
        )
        let luego = Playlist(name: "Escuchar luego", episodeIDs: [])

        return [gimnasio, mananas, tech, luego]
    }

    private static func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 86400)
    }
}
