import XCTest
@testable import Unicast

/// El corazón de la app: decidir qué episodio del feed es nuevo y cuál ya teníamos.
///
/// Aquí han vivido los peores fallos de Unicast, y ninguno daba error: simplemente desaparecían
/// episodios, o se volvían a descargar enteros. Cada prueba de este archivo corresponde a un fallo
/// REAL que llegó al iPhone del usuario.
@MainActor
final class FusionDeEpisodiosTests: XCTestCase {

    // MARK: - Utilidades

    private func episodio(_ titulo: String, guid: String? = nil, descargado: Bool = false,
                          posicion: TimeInterval = 0, fecha: Date = Date()) -> Episode {
        Episode(title: titulo, podcastTitle: "P", colorHex: "FFFFFF",
                audioURL: URL(string: "https://ejemplo.test/a.mp3"), duration: 100,
                publishedAt: fecha, isDownloaded: descargado, playbackPosition: posicion, guid: guid)
    }

    private func store(con episodios: [Episode]) -> AppStore {
        let store = AppStore()
        store.podcasts = [Podcast(title: "P", author: "A", colorHex: "FFFFFF", episodes: episodios)]
        return store
    }

    private func feed(_ episodios: [Episode]) -> Podcast {
        Podcast(title: "P", author: "A", colorHex: "FFFFFF", episodes: episodios)
    }

    // MARK: - Traspaso desde la biblioteca antigua

    /// LA PRUEBA MÁS IMPORTANTE DE TODAS. La biblioteca real del usuario tiene 7.455 episodios
    /// guardados SIN identificador, porque se guardaron antes de que se leyera el <guid>. Si el
    /// traspaso falla, la primera actualización duplica la biblioteca entera y se pone a
    /// re-descargar 7,5 GB.
    func testLaBibliotecaAntiguaNoSeDuplicaAlAdoptarLosIdentificadores() {
        let fechas = (0..<300).map { Date(timeIntervalSince1970: 1_700_000_000 - Double($0) * 86400) }
        let guardados = (0..<300).map {
            episodio("Capítulo \($0)", guid: nil, descargado: $0 < 5, fecha: fechas[$0])
        }
        let store = store(con: guardados)
        let nuevos = store.merge(feed((0..<300).map {
            episodio("Capítulo \($0)", guid: "g\($0)", fecha: fechas[$0])
        }), into: 0)

        XCTAssertTrue(nuevos.isEmpty, "Ningún episodio ya guardado puede entrar como nuevo")
        XCTAssertEqual(store.podcasts[0].episodes.count, 300, "La biblioteca no puede duplicarse")
        XCTAssertEqual(store.podcasts[0].episodes.filter(\.isDownloaded).count, 5,
                       "Lo descargado sigue descargado")
        XCTAssertTrue(store.podcasts[0].episodes.allSatisfy { $0.guid != nil },
                      "Todos deben haber adoptado su identificador")
    }

    func testQuinceRefrescosSeguidosNoAnadenNada() {
        let fecha = Date(timeIntervalSince1970: 1_700_000_000)
        let store = store(con: [episodio("Uno", guid: "g1", fecha: fecha)])
        let mismo = feed([episodio("Uno", guid: "g1", fecha: fecha)])
        for _ in 0..<15 { _ = store.merge(mismo, into: 0) }
        XCTAssertEqual(store.podcasts[0].episodes.count, 1)
    }

    // MARK: - Detección de lo nuevo

    func testUnEpisodioNuevoSeDetecta() {
        let fecha = Date(timeIntervalSince1970: 1_700_000_000)
        let store = store(con: [episodio("Viejo", guid: "g1", fecha: fecha)])
        let nuevos = store.merge(feed([episodio("Nuevo", guid: "g2", fecha: fecha.addingTimeInterval(86400)),
                                       episodio("Viejo", guid: "g1", fecha: fecha)]), into: 0)
        XCTAssertEqual(nuevos.count, 1)
        XCTAssertEqual(nuevos.first?.guid, "g2")
        XCTAssertEqual(store.podcasts[0].episodes.count, 2)
    }

    /// Fallo real: si el autor corregía una errata del título, el episodio entraba OTRA VEZ como
    /// nuevo y se volvía a descargar entero, aunque ya estuviera en el móvil.
    func testCorregirElTituloNoCreaUnEpisodioNuevo() {
        let fecha = Date(timeIntervalSince1970: 1_700_000_000)
        let store = store(con: [episodio("Capitlo con errata", guid: "g1", descargado: true, fecha: fecha)])
        let nuevos = store.merge(feed([episodio("Capítulo con errata corregida", guid: "g1", fecha: fecha)]), into: 0)

        XCTAssertTrue(nuevos.isEmpty, "Es el mismo episodio: el identificador manda sobre el título")
        XCTAssertEqual(store.podcasts[0].episodes.count, 1, "No puede duplicarse")
        XCTAssertEqual(store.podcasts[0].episodes[0].title, "Capítulo con errata corregida",
                       "El título sí debe actualizarse")
        XCTAssertTrue(store.podcasts[0].episodes[0].isDownloaded,
                      "No puede perder la descarga que ya tenía")
    }

    /// EL CASO REAL que se perdió en el iPhone del usuario: "Todo por la radio" (Cadena SER)
    /// publicó el 15/09/2026 un capítulo con el título EXACTO de otro del 07/07/2026. Como la
    /// identidad era el título, el de septiembre nunca entró en la biblioteca. Sin error, sin
    /// aviso, sin rastro.
    func testDosEpisodiosConElMismoTituloSonDosEpisodios() {
        let julio = Date(timeIntervalSince1970: 1_783_000_000)
        let septiembre = julio.addingTimeInterval(70 * 86400)
        let titulo = "Mi humilde opinión | La Prados trae su opinión semanal | Todo por la radio"

        // Lo guardado: el de julio, descargado y por el minuto 10, SIN identificador.
        let store = store(con: [episodio(titulo, guid: nil, descargado: true, posicion: 600, fecha: julio)])
        let nuevos = store.merge(feed([episodio(titulo, guid: "ser-sept", fecha: septiembre),
                                       episodio(titulo, guid: "ser-julio", fecha: julio)]), into: 0)

        XCTAssertEqual(nuevos.count, 1, "El capítulo de septiembre SÍ tiene que entrar")
        XCTAssertEqual(nuevos.first?.guid, "ser-sept")
        XCTAssertEqual(store.podcasts[0].episodes.count, 2, "Tienen que quedar los dos")

        // Y cada uno con su identidad: el de julio no puede perder su audio ni su posición.
        let deJulio = store.podcasts[0].episodes.first { $0.publishedAt == julio }
        XCTAssertEqual(deJulio?.guid, "ser-julio", "El de julio conserva SU identificador")
        XCTAssertEqual(deJulio?.isDownloaded, true)
        XCTAssertEqual(deJulio?.playbackPosition, 600)

        let deSeptiembre = store.podcasts[0].episodes.first { $0.guid == "ser-sept" }
        XCTAssertEqual(deSeptiembre?.isDownloaded, false,
                       "El de septiembre no puede heredar el audio del de julio")
    }

    // MARK: - Feeds que no traen identificador

    func testUnFeedSinIdentificadoresSigueFuncionandoPorTitulo() {
        let store = store(con: [episodio("Uno"), episodio("Dos")])
        let nuevos = store.merge(feed([episodio("Tres"), episodio("Uno"), episodio("Dos")]), into: 0)
        XCTAssertEqual(nuevos.count, 1)
        XCTAssertEqual(nuevos.first?.title, "Tres")
        XCTAssertEqual(store.podcasts[0].episodes.count, 3)
    }

    func testUnFeedQueRepiteElMismoIdentificadorNoDuplica() {
        let store = store(con: [])
        let nuevos = store.merge(feed([episodio("Uno", guid: "g1"), episodio("Uno otra vez", guid: "g1")]), into: 0)
        XCTAssertEqual(nuevos.count, 1, "El mismo identificador dos veces es un episodio, no dos")
    }

    // MARK: - Lo que el refresco NUNCA puede tocar

    func testElRefrescoNoPisaElEstadoDelUsuario() {
        let fecha = Date(timeIntervalSince1970: 1_700_000_000)
        var guardado = episodio("Uno", guid: "g1", descargado: true, posicion: 1234, fecha: fecha)
        guardado.isPlayed = true
        guardado.manuallyDownloaded = true
        let store = store(con: [guardado])

        _ = store.merge(feed([episodio("Uno", guid: "g1", fecha: fecha)]), into: 0)

        let despues = store.podcasts[0].episodes[0]
        XCTAssertTrue(despues.isDownloaded, "El refresco no puede desmarcar una descarga")
        XCTAssertEqual(despues.playbackPosition, 1234, "Ni perder dónde se quedó")
        XCTAssertTrue(despues.isPlayed, "Ni resucitar un episodio ya escuchado")
        XCTAssertTrue(despues.manuallyDownloaded, "Ni olvidar que lo bajó a mano")
    }
}
