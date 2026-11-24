import Foundation

// Descubrir (versión 2, 24/11/2026). Antes buscaba el NOMBRE de la categoría en el buscador de Apple
// (devolvía resultados genéricos). Ahora:
//  1. Mira TODOS los podcasts que sigues y averigua su categoría real.
//  2. Por cada categoría fuerte, toma las listas de los más populares de Apple en varios países.
//  3. Añade búsquedas con las palabras más repetidas en las descripciones de lo que sigues.
//  4. Puntúa (posición en las listas + tema), quita lo que ya sigues o lleva meses sin publicar,
//     y enseña de dónde sale cada recomendación (posición en la lista y tema).
// Solo usa datos públicos de Apple (sin claves ni cuentas).

/// Una recomendación de Descubrir: el podcast y por qué se propone.
struct Recommendation: Identifiable, Hashable {
    let result: SearchResult
    let rankText: String?     // «nº 7 en Historia · España»
    let topicText: String?    // «relacionado con «roma»»
    var id: Int { result.id }
}

/// Un grupo de recomendaciones de una categoría, con los podcasts tuyos en los que se basa.
struct RecommendationSection: Identifiable {
    let genre: String
    let basedOn: [String]
    let items: [Recommendation]
    var id: String { genre }
}

/// Lo mínimo que hace falta saber de un podcast que sigues.
struct FollowedPodcast: Sendable {
    let title: String
    let summary: String
    let feedURL: URL?
}

enum DescubrirEngine {

    struct Pais: Sendable {
        let code: String
        let nombre: String
    }

    /// Países de los que se miran las listas, según el idioma elegido en la pantalla.
    static func paises(idioma: String) -> [Pais] {
        if idioma == "US" {
            return [Pais(code: "us", nombre: "Estados Unidos"), Pais(code: "gb", nombre: "Reino Unido")]
        }
        return [Pais(code: "es", nombre: "España"), Pais(code: "mx", nombre: "México"),
                Pais(code: "ar", nombre: "Argentina")]
    }

    struct GeneroSeguido {
        let id: String
        var nombre: String
        var seguidos: [String]
        var resumenes: [String]
    }

    // MARK: - Punto de entrada

    static func recomendar(seguidos: [FollowedPodcast], idioma: String) async -> [RecommendationSection] {
        let paises = paises(idioma: idioma)
        guard let principal = paises.first, !seguidos.isEmpty else { return [] }

        let (generos, idsSeguidos) = await generosSeguidos(seguidos, country: principal.code)
        let titulos = Set(seguidos.map { normalizar($0.title) })
        let feeds = Set(seguidos.compactMap { $0.feedURL.map { normalizarFeed($0.absoluteString) } })

        var secciones: [RecommendationSection] = []
        for genero in generos.prefix(3) {
            if let seccion = await seccion(para: genero, paises: paises, idsSeguidos: idsSeguidos,
                                           titulos: titulos, feeds: feeds) {
                secciones.append(seccion)
            }
        }
        return secciones
    }

    // MARK: - 1. Categorías de lo que sigues

    /// Categoría real de cada podcast que sigues (buscándolo en Apple y exigiendo que sea EL MISMO podcast).
    static func generosSeguidos(_ seguidos: [FollowedPodcast], country: String)
        async -> (generos: [GeneroSeguido], ids: Set<Int>) {
        let lista = Array(seguidos.prefix(40))
        var emparejados: [(FollowedPodcast, SearchResult)] = []
        for inicio in stride(from: 0, to: lista.count, by: 6) {
            let trozo = Array(lista[inicio..<min(inicio + 6, lista.count)])
            await withTaskGroup(of: (FollowedPodcast, SearchResult?).self) { grupo in
                for podcast in trozo {
                    grupo.addTask { (podcast, await emparejar(podcast, country: country)) }
                }
                for await (podcast, resultado) in grupo {
                    if let resultado { emparejados.append((podcast, resultado)) }
                }
            }
        }
        var porGenero: [String: GeneroSeguido] = [:]
        var ids = Set<Int>()
        for (podcast, resultado) in emparejados {
            ids.insert(resultado.id)
            guard let (id, nombre) = generoPrincipal(de: resultado) else { continue }
            var g = porGenero[id] ?? GeneroSeguido(id: id, nombre: nombre, seguidos: [], resumenes: [])
            g.seguidos.append(podcast.title)
            g.resumenes.append(podcast.summary)
            porGenero[id] = g
        }
        let ordenados = porGenero.values.sorted {
            $0.seguidos.count != $1.seguidos.count ? $0.seguidos.count > $1.seguidos.count : $0.nombre < $1.nombre
        }
        return (ordenados, ids)
    }

    private static func emparejar(_ podcast: FollowedPodcast, country: String) async -> SearchResult? {
        let resultados = await buscar(podcast.title, country: country)
        if let feed = podcast.feedURL.map({ normalizarFeed($0.absoluteString) }),
           let igual = resultados.first(where: { $0.feedUrl.map(normalizarFeed) == feed }) {
            return igual
        }
        let titulo = normalizar(podcast.title)
        return resultados.first { normalizar($0.collectionName) == titulo }
    }

    /// Id y nombre de la categoría principal (ignora la genérica «Podcasts», id 26).
    static func generoPrincipal(de resultado: SearchResult) -> (String, String)? {
        guard let ids = resultado.genreIds else { return nil }
        if let nombre = resultado.primaryGenreName, let nombres = resultado.genres,
           let indice = nombres.firstIndex(of: nombre), indice < ids.count, ids[indice] != "26" {
            return (ids[indice], nombre)
        }
        if let id = ids.first(where: { $0 != "26" }) {
            return (id, resultado.primaryGenreName ?? id)
        }
        return nil
    }

    // MARK: - 2-4. Candidatos, puntuación y filtros

    private static func seccion(para genero: GeneroSeguido, paises: [Pais], idsSeguidos: Set<Int>,
                                titulos: Set<String>, feeds: Set<String>) async -> RecommendationSection? {
        var puntos: [Int: Double] = [:]
        var mejor: [Int: (pais: Pais, rank: Int)] = [:]

        // Listas de más populares de esa categoría, en cada país.
        await withTaskGroup(of: (Pais, [(Int, Int)]).self) { grupo in
            for pais in paises { grupo.addTask { (pais, await listaPopulares(pais: pais.code, genero: genero.id)) } }
            for await (pais, lista) in grupo {
                for (id, rank) in lista {
                    puntos[id, default: 0] += Double(51 - rank) / 50
                    if mejor[id] == nil || rank < mejor[id]!.rank { mejor[id] = (pais, rank) }
                }
            }
        }

        // Búsquedas con las palabras más repetidas en lo que sigues de esa categoría.
        var temas: [Int: String] = [:]
        var encontrados: [Int: SearchResult] = [:]
        let claves = palabrasClave(de: genero.resumenes + genero.seguidos, excluyendo: [genero.nombre])
        for clave in claves {
            for r in await buscar(clave, country: paises[0].code) where r.genreIds?.contains(genero.id) == true {
                puntos[r.id, default: 0] += 0.8
                temas[r.id] = temas[r.id] ?? clave
                encontrados[r.id] = r
            }
        }

        // Datos completos (feed, última publicación, nº de episodios) de los mejor puntuados.
        let candidatos = puntos.sorted { $0.value > $1.value }.map(\.key)
            .filter { !idsSeguidos.contains($0) }.prefix(40)
        var datos = encontrados
        let faltan = candidatos.filter { datos[$0] == nil }
        for r in await detalles(ids: Array(faltan), country: paises[0].code) { datos[r.id] = r }

        let limite = Date().addingTimeInterval(-120 * 86400)
        let elegidos: [Recommendation] = candidatos.compactMap { id in
            guard let r = datos[id], let feed = r.feedUrl else { return nil }
            if titulos.contains(normalizar(r.collectionName)) || feeds.contains(normalizarFeed(feed)) { return nil }
            if let n = r.trackCount, n < 5 { return nil }
            if let fecha = r.releaseDate.flatMap(parsearFecha), fecha < limite { return nil }
            let rank = mejor[id].map { "nº \($0.rank) en \(genero.nombre) · \($0.pais.nombre)" }
            let tema = temas[id].map { "relacionado con «\($0)»" }
            return Recommendation(result: r, rankText: rank, topicText: tema)
        }
        .sorted { (puntos[$0.id] ?? 0) > (puntos[$1.id] ?? 0) }

        guard !elegidos.isEmpty else { return nil }
        return RecommendationSection(genre: genero.nombre, basedOn: Array(genero.seguidos.prefix(4)),
                                     items: Array(elegidos.prefix(8)))
    }

    // MARK: - Palabras clave de las descripciones

    /// Las palabras más repetidas (≥ 5 letras, sin palabras vacías) en esos textos.
    static func palabrasClave(de textos: [String], excluyendo: [String] = [], max: Int = 3) -> [String] {
        let propias = Set(excluyendo.flatMap { palabras(en: $0) })
        var cuenta: [String: Int] = [:]
        for texto in textos {
            let limpio = texto
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
            for palabra in Set(palabras(en: limpio)) where palabra.count >= 5
                && !palabrasVacias.contains(palabra) && !propias.contains(palabra) {
                cuenta[palabra, default: 0] += 1
            }
        }
        return cuenta.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(max).map(\.key)
    }

    private static func palabras(en texto: String) -> [String] {
        texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    private static let palabrasVacias: Set<String> = [
        "podcast", "podcasts", "episodio", "episodios", "programa", "programas", "semana", "semanal",
        "semanas", "escucha", "escuchar", "escuchas", "spotify", "apple", "suscribete", "suscribirse",
        "comparte", "descubre", "contenido", "cuando", "donde", "desde", "hasta", "sobre", "entre",
        "tambien", "ademas", "porque", "aunque", "mientras", "siempre", "ahora", "todos", "todas",
        "cada", "nuestro", "nuestra", "nuestros", "nuestras", "tiene", "tienen", "hacer", "estas",
        "estos", "otros", "otras", "mucho", "mucha", "mucho", "puedes", "puede", "podemos", "gente",
        "mundo", "lunes", "martes", "jueves", "viernes", "sabado", "domingo", "https", "about", "their",
        "which", "where", "while", "these", "those", "other", "every", "weekly", "episode", "episodes",
        "listen", "learn", "world", "people", "stories", "story", "hosted", "host", "show", "shows",
        "year", "years", "week", "daily", "there", "would", "could", "should", "being", "really",
        "joins", "join", "series", "season", "subscribe", "follow", "available", "latest", "check",
    ]

    // MARK: - Apple (datos públicos)

    /// Busca podcasts en el buscador de Apple.
    static func buscar(_ term: String, country: String, limit: Int = 25) async -> [SearchResult] {
        let limpio = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, var comps = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "term", value: limpio),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return await descargarResultados(comps.url)
    }

    /// Datos completos de varios podcasts por su id (en trozos, la API admite muchos a la vez).
    static func detalles(ids: [Int], country: String) async -> [SearchResult] {
        var todos: [SearchResult] = []
        for inicio in stride(from: 0, to: ids.count, by: 100) {
            let trozo = ids[inicio..<min(inicio + 100, ids.count)].map(String.init).joined(separator: ",")
            guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { continue }
            comps.queryItems = [
                URLQueryItem(name: "id", value: trozo),
                URLQueryItem(name: "entity", value: "podcast"),
                URLQueryItem(name: "country", value: country),
            ]
            todos += await descargarResultados(comps.url)
        }
        return todos
    }

    private static func descargarResultados(_ url: URL?) async -> [SearchResult] {
        guard let url, let (datos, _) = try? await URLSession.shared.data(from: url),
              let respuesta = try? JSONDecoder().decode(ITunesResponse.self, from: datos)
        else { return [] }
        return respuesta.results.filter { $0.feedUrl != nil }
    }

    /// Los 50 podcasts más populares de una categoría en un país: pares (id del podcast, posición).
    static func listaPopulares(pais: String, genero: String) async -> [(Int, Int)] {
        guard let url = URL(string: "https://itunes.apple.com/\(pais)/rss/toppodcasts/limit=50/genre=\(genero)/json"),
              let (datos, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let feed = json["feed"] as? [String: Any] else { return [] }
        let entradas = (feed["entry"] as? [[String: Any]]) ?? (feed["entry"] as? [String: Any]).map { [$0] } ?? []
        return entradas.enumerated().compactMap { indice, entrada in
            guard let id = entrada["id"] as? [String: Any],
                  let atributos = id["attributes"] as? [String: Any],
                  let texto = atributos["im:id"] as? String, let numero = Int(texto) else { return nil }
            return (numero, indice + 1)
        }
    }

    // MARK: - Utilidades

    static func normalizar(_ texto: String) -> String {
        texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func normalizarFeed(_ url: String) -> String {
        var s = url.lowercased()
        for prefijo in ["https://", "http://", "www."] where s.hasPrefix(prefijo) { s.removeFirst(prefijo.count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func parsearFecha(_ texto: String) -> Date? {
        ISO8601DateFormatter().date(from: texto)
    }
}
