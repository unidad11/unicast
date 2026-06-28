import Foundation

/// Servicio de podcasts: buscar en el directorio público de iTunes/Apple Podcasts
/// y descargar/parsear feeds RSS. Todo con URLSession nativo, sin dependencias.
enum PodcastService {

    /// Busca podcasts por nombre en la iTunes Search API.
    static func search(_ term: String) async -> [SearchResult] {
        let cleaned = term.trimmed
        guard !cleaned.isEmpty,
              var components = URLComponents(string: "https://itunes.apple.com/search")
        else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: cleaned),
            URLQueryItem(name: "media", value: "podcast"),
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

    /// Descubre podcasts parecidos a los que sigue el usuario, por género (directorio de Apple, gratis).
    static func discover(from podcasts: [Podcast]) async -> [SearchResult] {
        // Géneros de hasta 5 podcasts seguidos (consultando iTunes por su nombre).
        var genres: [String] = []
        for podcast in podcasts.prefix(5) {
            if let match = await search(podcast.title).first, let genre = match.primaryGenreName {
                genres.append(genre)
            }
        }
        // Los 2 géneros más repetidos entre lo que sigue.
        let topGenres = Dictionary(grouping: genres, by: { $0 })
            .sorted { $0.value.count > $1.value.count }
            .prefix(2).map(\.key)
        guard !topGenres.isEmpty else { return [] }
        // Podcasts de esos géneros que el usuario aún NO sigue (sin repetir).
        let followed = Set(podcasts.map(\.title))
        var seen = Set<Int>()
        var recommendations: [SearchResult] = []
        for genre in topGenres {
            for result in await search(genre)
            where !followed.contains(result.collectionName) && seen.insert(result.id).inserted {
                recommendations.append(result)
            }
        }
        return recommendations
    }
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
