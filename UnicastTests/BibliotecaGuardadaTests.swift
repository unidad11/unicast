import XCTest
@testable import Unicast

/// Guardar y recuperar la biblioteca. Un fallo aquí no se nota en el momento: se nota cuando el
/// usuario abre la app y le faltan 25 podcasts.
final class BibliotecaGuardadaTests: XCTestCase {

    private func episodio(_ titulo: String) -> Episode {
        Episode(title: titulo, summary: "Resumen", podcastTitle: "P", colorHex: "FFFFFF",
                artworkURL: URL(string: "https://ejemplo.test/i.jpg"),
                audioURL: URL(string: "https://ejemplo.test/a.mp3"), duration: 3600,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isDownloaded: true, isPlayed: false, playbackPosition: 42,
                chapters: [Chapter(title: "Intro «con comillas» y emoji 🎧", start: 0, colorHex: "FFFFFF")],
                manuallyDownloaded: true, audioBytes: 157_286_400, guid: "g-1")
    }

    private func estado() -> AppState {
        let podcast = Podcast(title: "P", author: "A", summary: "S",
                              feedURL: URL(string: "https://ejemplo.test/feed"), colorHex: "FFFFFF",
                              episodes: [episodio("Uno"), episodio("Dos")],
                              downloadLimit: .last(7),
                              downloadFromDate: Date(timeIntervalSince1970: 1))
        return AppState(podcasts: [podcast],
                        playlists: [Playlist(name: "Mi lista", episodeIDs: [podcast.episodes[0].id])],
                        backgroundStyle: .amber, showNewCountBadges: true, libraryLayout: .decks,
                        wifiOnlyDownloads: false, defaultDownloadLimit: .all,
                        nowPlayingID: podcast.episodes[0].id)
    }

    private func idaYVuelta(_ estado: AppState) throws -> AppState {
        try JSONDecoder().decode(AppState.self, from: try JSONEncoder().encode(estado))
    }

    // MARK: - Ida y vuelta

    func testLoQueSeGuardaSeRecuperaIgual() throws {
        let original = estado()
        let vuelta = try idaYVuelta(original)

        XCTAssertEqual(vuelta.podcasts.count, 1)
        XCTAssertEqual(vuelta.podcasts[0].episodes.count, 2)
        XCTAssertEqual(vuelta.podcasts[0].episodes[0].id, original.podcasts[0].episodes[0].id)
        XCTAssertEqual(vuelta.podcasts[0].episodes[0].playbackPosition, 42)
        XCTAssertEqual(vuelta.podcasts[0].episodes[0].guid, "g-1")
        XCTAssertEqual(vuelta.podcasts[0].episodes[0].audioBytes, 157_286_400)
        XCTAssertTrue(vuelta.podcasts[0].episodes[0].manuallyDownloaded)
        XCTAssertEqual(vuelta.podcasts[0].downloadLimit, .last(7))
        XCTAssertEqual(vuelta.backgroundStyle, .amber)
        XCTAssertEqual(vuelta.libraryLayout, .decks)
        XCTAssertEqual(vuelta.defaultDownloadLimit, .all)
        XCTAssertFalse(vuelta.wifiOnlyDownloads)
        XCTAssertEqual(vuelta.nowPlayingID, original.nowPlayingID)
        XCTAssertEqual(vuelta.playlists.first?.name, "Mi lista")
    }

    /// Cada campo nuevo que se añade al modelo es una oportunidad de dejar al usuario sin
    /// biblioteca. Se simula un archivo de una versión anterior quitando los campos recientes.
    func testUnArchivoDeUnaVersionAnteriorSigueCargando() throws {
        let datos = try JSONEncoder().encode(estado())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: datos) as? [String: Any])
        var podcasts = try XCTUnwrap(json["podcasts"] as? [[String: Any]])
        var episodios = try XCTUnwrap(podcasts[0]["episodes"] as? [[String: Any]])
        for campo in ["guid", "audioBytes", "manuallyDownloaded", "downloadFailures", "lastDownloadFailureAt"] {
            for i in episodios.indices { episodios[i].removeValue(forKey: campo) }
        }
        podcasts[0]["episodes"] = episodios
        json["podcasts"] = podcasts

        let viejo = try JSONSerialization.data(withJSONObject: json)
        let cargado = try JSONDecoder().decode(AppState.self, from: viejo)

        XCTAssertEqual(cargado.podcasts[0].episodes.count, 2, "No se puede perder ni un episodio")
        XCTAssertEqual(cargado.podcasts[0].episodes[0].playbackPosition, 42, "Ni dónde se quedó")
        XCTAssertNil(cargado.podcasts[0].episodes[0].guid)
        XCTAssertFalse(cargado.podcasts[0].episodes[0].manuallyDownloaded)
        XCTAssertEqual(cargado.podcasts[0].episodes[0].downloadFailures, 0)
    }

    // MARK: - Tolerancia a archivos dañados

    func testUnAjusteCorruptoNoSeLlevaPorDelanteLaBiblioteca() throws {
        let datos = try JSONEncoder().encode(estado())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: datos) as? [String: Any])
        json["backgroundStyle"] = "un_estilo_que_no_existe"
        json["defaultDownloadLimit"] = 12345
        json["libraryLayout"] = ["algo": "raro"]

        let cargado = try JSONDecoder().decode(AppState.self,
                                                from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(cargado.podcasts[0].episodes.count, 2, "La biblioteca se salva")
        XCTAssertEqual(cargado.backgroundStyle, .blueNight, "El ajuste roto cae a su valor por defecto")
    }

    func testUnEpisodioRotoNoSeLlevaPorDelanteLosDemas() throws {
        let datos = try JSONEncoder().encode(estado())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: datos) as? [String: Any])
        var podcasts = try XCTUnwrap(json["podcasts"] as? [[String: Any]])
        let bueno = try XCTUnwrap((podcasts[0]["episodes"] as? [[String: Any]])?.first)
        podcasts[0]["episodes"] = [["basura": "sin nada útil"], bueno, ["duration": "esto no es un número"]]
        json["podcasts"] = podcasts

        let cargado = try JSONDecoder().decode(AppState.self,
                                                from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(cargado.podcasts[0].episodes.count, 1,
                       "Los que no tienen identidad se descartan; el bueno sobrevive")
        XCTAssertEqual(cargado.podcasts[0].episodes[0].playbackPosition, 42)
    }

    func testUnNullEnMedioDeUnaListaNoCuelgaLaCarga() throws {
        let datos = try JSONEncoder().encode(estado())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: datos) as? [String: Any])
        let buena = try XCTUnwrap((json["playlists"] as? [[String: Any]])?.first)
        json["playlists"] = [NSNull(), buena, NSNull()]

        let cargado = try JSONDecoder().decode(AppState.self,
                                                from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(cargado.playlists.count, 1)
        XCTAssertEqual(cargado.playlists.first?.name, "Mi lista")
    }

    /// El nombre del archivo .mp3 en disco ES el id del episodio. Inventarle uno nuevo deja el
    /// audio huérfano (y la limpieza se lo lleva) y obliga a bajarlo otra vez entero.
    func testUnEpisodioSinIdentidadSeDescartaEnVezDeInventarleUna() throws {
        let datos = try JSONEncoder().encode(estado())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: datos) as? [String: Any])
        var podcasts = try XCTUnwrap(json["podcasts"] as? [[String: Any]])
        var episodios = try XCTUnwrap(podcasts[0]["episodes"] as? [[String: Any]])
        episodios[0].removeValue(forKey: "id")
        podcasts[0]["episodes"] = episodios
        json["podcasts"] = podcasts

        let cargado = try JSONDecoder().decode(AppState.self,
                                                from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(cargado.podcasts[0].episodes.count, 1, "El que no tiene id se descarta")
        XCTAssertEqual(cargado.podcasts[0].episodes[0].title, "Dos", "El otro sigue intacto")
    }
}
