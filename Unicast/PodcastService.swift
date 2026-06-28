import Foundation

/// Servicio de podcasts: buscar en el directorio público de iTunes/Apple Podcasts
/// y descargar/parsear feeds RSS. Todo con URLSession nativo, sin dependencias.
enum PodcastService {

    /// Busca podcasts por nombre en la iTunes Search API.
    static func search(_ term: String, country: String = "US") async -> [SearchResult] {
        let cleaned = term.trimmed
        guard !cleaned.isEmpty,
              var components = URLComponents(string: "https://itunes.apple.com/search")
        else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: cleaned),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(ITunesResponse.self, from: data)
        else { return [] }
        return response.results.filter { $0.feedUrl != nil }
    }

    /// Descarga y parsea un feed RSS, devolviendo el podcast con sus episodios.
    static func fetchPodcast(feedURL: URL, colorHex: String = "5B5BD6",
                             user: String? = nil, password: String? = nil) async -> Podcast? {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData   // feed SIEMPRE fresco (como Overcast)
        // Podcast privado: autenticación básica (usuario y contraseña).
        if let user, let password, !user.isEmpty,
           let credentials = "\(user):\(password)".data(using: .utf8) {
            request.setValue("Basic \(credentials.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return RSSParser(feedURL: feedURL, colorHex: colorHex).parse(data: data)
    }

    /// Detecta las categorías de lo que sigue el usuario y, por cada una, propone podcasts de
    /// esa categoría que aún no sigue. `country` elige la tienda (ES = español, US = inglés).
    static func discover(from podcasts: [Podcast], country: String) async -> [GenreSection] {
        // Categorías de hasta 6 seguidos (con el nombre en el idioma de la tienda consultada).
        var genreCounts: [String: Int] = [:]
        for podcast in podcasts.prefix(6) {
            if let match = await search(podcast.title, country: country).first,
               let genre = match.primaryGenreName {
                genreCounts[genre, default: 0] += 1
            }
        }
        // Hasta 4 categorías, las más repetidas primero.
        let topGenres = genreCounts.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        guard !topGenres.isEmpty else { return [] }
        // Por cada categoría, podcasts de ese estilo que el usuario aún NO sigue (sin repetir).
        let followed = Set(podcasts.map(\.title))
        var seen = Set<Int>()
        var sections: [GenreSection] = []
        for genre in topGenres {
            var results: [SearchResult] = []
            for result in await search(genre, country: country)
            where !followed.contains(result.collectionName) && seen.insert(result.id).inserted {
                results.append(result)
            }
            if !results.isEmpty {
                sections.append(GenreSection(genre: genre, results: Array(results.prefix(8))))
            }
        }
        return sections
    }
}

/// Un grupo de recomendaciones de Descubrir, bajo el nombre de su categoría.
struct GenreSection: Identifiable {
    let genre: String
    let results: [SearchResult]
    var id: String { genre }
}

/// Respuesta de la iTunes Search API.
struct ITunesResponse: Decodable {
    let results: [SearchResult]
}

/// Un podcast encontrado en el directorio de iTunes.
struct SearchResult: Decodable, Identifiable, Hashable {
    let collectionId: Int
    let collectionName: String
    let artistName: String
    let feedUrl: String?
    let artworkUrl100: String?
    let artworkUrl600: String?
    let primaryGenreName: String?

    var id: Int { collectionId }
    var artwork: URL? { URL(string: artworkUrl600 ?? artworkUrl100 ?? "") }
    var feed: URL? { feedUrl.flatMap(URL.init(string:)) }
}
