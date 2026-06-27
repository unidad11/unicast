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
        // Podcast privado: autenticación básica (usuario y contraseña).
        if let user, let password, !user.isEmpty,
           let credentials = "\(user):\(password)".data(using: .utf8) {
            request.setValue("Basic \(credentials.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return RSSParser(feedURL: feedURL, colorHex: colorHex).parse(data: data)
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

    var id: Int { collectionId }
    var artwork: URL? { URL(string: artworkUrl600 ?? artworkUrl100 ?? "") }
    var feed: URL? { feedUrl.flatMap(URL.init(string:)) }
}
