import Foundation
import Observation

// «Selección de Claude» en Descubrir (24/11/2026).
// Unicast sube la lista de podcasts que sigues al servidor de sincronización de Marcadores (en el Mac mini)
// y, minutos después, el Mac mini le devuelve una selección hecha por Claude (con tu suscripción), ya
// comprobada en Apple y con una razón por cada podcast. La clave de sincronización la pega Juan una vez
// (queda en el llavero); en el código no hay ninguna clave ni dirección.

/// Un podcast propuesto por Claude (ya comprobado en Apple por el Mac mini).
struct ClaudePick: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let author: String
    let artwork: String
    let feed: String
    let genre: String?
    let episodes: Int?
    let reason: String
    let basedOn: [String]?

    /// Para poder seguirlo con el mismo botón que el resto de Descubrir.
    var searchResult: SearchResult {
        SearchResult(collectionId: id, collectionName: title, artistName: author, feedUrl: feed,
                     artworkUrl100: artwork, artworkUrl600: artwork, primaryGenreName: genre,
                     genreIds: nil, genres: nil, releaseDate: nil, trackCount: episodes)
    }
}

struct ClaudeSelection: Codable {
    let generado: Int64          // milisegundos desde 1970
    let items: [ClaudePick]
    var fecha: Date { Date(timeIntervalSince1970: TimeInterval(generado) / 1000) }
}

@MainActor
@Observable
final class ClaudePicksService {
    static let shared = ClaudePicksService()

    enum PicksError: LocalizedError {
        case claveNoValida, sinConexion, servidor(Int), respuesta
        var errorDescription: String? {
            switch self {
            case .claveNoValida: return "El servidor no acepta la clave. Revísala."
            case .sinConexion: return "No hay conexión con el servidor. Se reintentará."
            case .servidor(let c): return "El servidor respondió con un error (\(c))."
            case .respuesta: return "Respuesta del servidor no válida."
            }
        }
    }

    private static let claveLlavero = "descubrir-sync-token"
    private let defaults = UserDefaults.standard

    private(set) var selection: ClaudeSelection?
    private(set) var isWorking = false
    private(set) var isWaiting = false
    var message: String?
    private var pollTask: Task<Void, Never>?

    var serverURL: String {
        get { defaults.string(forKey: "descubrirURL") ?? "" }
        set { defaults.set(newValue, forKey: "descubrirURL") }
    }
    var isConfigured: Bool { !serverURL.isEmpty && Keychain.load(Self.claveLlavero) != nil }

    private init() {
        if let datos = defaults.data(forKey: "descubrirSeleccion"),
           let guardada = try? JSONDecoder().decode(ClaudeSelection.self, from: datos) {
            selection = guardada
        }
    }

    // MARK: - Conexión

    /// Prueba la dirección y la clave; si valen, las guarda (la clave, en el llavero).
    func connect(url: String, token: String) async -> Bool {
        let base = Self.limpiar(url)
        let clave = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !clave.isEmpty else { message = "Escribe la dirección y la clave."; return false }
        do {
            _ = try await llamar(base: base, token: clave, ruta: "/v1/me", metodo: "GET", cuerpo: nil)
            serverURL = base
            Keychain.save(clave, for: Self.claveLlavero)
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        pollTask?.cancel()
        Keychain.delete(Self.claveLlavero)
        defaults.removeObject(forKey: "descubrirURL")
        defaults.removeObject(forKey: "descubrirSeq")
        defaults.removeObject(forKey: "descubrirSeleccion")
        defaults.removeObject(forKey: "descubrirHuella")
        selection = nil
        isWaiting = false
    }

    // MARK: - Sincronización

    /// Sube lo que sigues (si cambió o si se pide refrescar) y trae la última selección.
    func refresh(podcasts: [Podcast], language: String, force: Bool) async {
        guard isConfigured, !podcasts.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            var cambios: [[String: Any]] = []
            let huella = Self.huella(podcasts, idioma: language)
            if force || huella != defaults.string(forKey: "descubrirHuella") {
                let ahora = Self.ahoraMs()
                if force { defaults.set(ahora, forKey: "descubrirPedido") }
                let pedido = (defaults.object(forKey: "descubrirPedido") as? Int64) ?? 0
                let datos: [String: Any] = ["podcasts": Self.resumen(podcasts), "idioma": language, "pedido": pedido]
                cambios.append(["kind": "podcast_seguidos", "id": "yo", "updated": ahora,
                                "deleted": false, "data": datos])
            }
            let respuesta = try await sincronizar(cambios: cambios)
            aplicar(respuesta)
            if !cambios.isEmpty { defaults.set(huella, forKey: "descubrirHuella") }
            message = nil
            let pedido = (defaults.object(forKey: "descubrirPedido") as? Int64) ?? 0
            if force || selection == nil || (selection?.generado ?? 0) < pedido { esperarSeleccion() }
        } catch {
            message = error.localizedDescription     // se sigue enseñando la última selección guardada
        }
    }

    /// Mientras el Mac mini prepara la selección, mira cada 15 s (hasta 6 min) si ya está.
    private func esperarSeleccion() {
        guard pollTask == nil else { return }
        isWaiting = (selection == nil) || (selection?.generado ?? 0) < ((defaults.object(forKey: "descubrirPedido") as? Int64) ?? 0)
        guard isWaiting else { return }
        pollTask = Task { [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { break }
                if let r = try? await self.sincronizar(cambios: []) { self.aplicar(r) }
                let pedido = (self.defaults.object(forKey: "descubrirPedido") as? Int64) ?? 0
                if let s = self.selection, s.generado >= pedido { break }
            }
            self?.isWaiting = false
            self?.pollTask = nil
        }
    }

    private func sincronizar(cambios: [[String: Any]]) async throws -> [String: Any] {
        guard let token = Keychain.load(Self.claveLlavero) else { throw PicksError.claveNoValida }
        let since = defaults.integer(forKey: "descubrirSeq")
        let cuerpo: [String: Any] = ["since": since, "changes": cambios, "kinds": ["podcast_seleccion"]]
        return try await llamar(base: serverURL, token: token, ruta: "/v1/sync", metodo: "POST", cuerpo: cuerpo)
    }

    private func aplicar(_ respuesta: [String: Any]) {
        if let seq = respuesta["seq"] as? Int { defaults.set(seq, forKey: "descubrirSeq") }
        for cambio in respuesta["changes"] as? [[String: Any]] ?? []
        where cambio["kind"] as? String == "podcast_seleccion" && cambio["id"] as? String == "yo"
            && (cambio["deleted"] as? Bool) != true {
            guard let datos = cambio["data"],
                  let json = try? JSONSerialization.data(withJSONObject: datos),
                  let nueva = try? JSONDecoder().decode(ClaudeSelection.self, from: json) else { continue }
            selection = nueva
            defaults.set(json, forKey: "descubrirSeleccion")
        }
    }

    // MARK: - Red

    private func llamar(base: String, token: String, ruta: String, metodo: String,
                        cuerpo: [String: Any]?) async throws -> [String: Any] {
        guard let url = URL(string: base + ruta) else { throw PicksError.respuesta }
        var peticion = URLRequest(url: url, timeoutInterval: 30)
        peticion.httpMethod = metodo
        peticion.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let cuerpo {
            peticion.setValue("application/json", forHTTPHeaderField: "Content-Type")
            peticion.httpBody = try JSONSerialization.data(withJSONObject: cuerpo)
        }
        let datos: Data, respuesta: URLResponse
        do { (datos, respuesta) = try await URLSession.shared.data(for: peticion) }
        catch { throw PicksError.sinConexion }
        guard let http = respuesta as? HTTPURLResponse else { throw PicksError.respuesta }
        if http.statusCode == 401 { throw PicksError.claveNoValida }
        guard http.statusCode == 200 else { throw PicksError.servidor(http.statusCode) }
        guard let objeto = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else { throw PicksError.respuesta }
        return objeto
    }

    // MARK: - Utilidades

    nonisolated static func limpiar(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    nonisolated static func ahoraMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Cambia solo si cambian los podcasts que sigues (o el idioma), no por escuchar un episodio.
    nonisolated static func huella(_ podcasts: [Podcast], idioma: String) -> String {
        (podcasts.map(\.title).sorted() + [idioma]).joined(separator: "|")
    }

    nonisolated static func resumen(_ podcasts: [Podcast]) -> [[String: Any]] {
        podcasts.prefix(60).map { p in
            ["title": p.title, "author": p.author, "summary": String(p.summary.prefix(400)),
             "feedURL": p.feedURL?.absoluteString ?? "", "played": p.episodes.filter(\.isPlayed).count]
        }
    }
}
