import XCTest
@testable import Unicast

/// Lectura de un feed RSS real. Se prueba por la puerta de delante (`RSSParser.parse`), con XML
/// de verdad, no llamando a funciones internas: así la prueba sigue valiendo aunque se
/// reorganicen las tripas del parser.
final class LecturaDeFeedsTests: XCTestCase {

    private func feedXML(item: String) -> Data {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>Podcast de prueba</title>
          <itunes:author>Autor</itunes:author>
          <description>Una descripción</description>
          \(item)
        </channel>
        </rss>
        """.data(using: .utf8)!
    }

    private func primerEpisodio(fecha: String) -> Episode? {
        let xml = feedXML(item: """
          <item>
            <title>Capítulo de prueba</title>
            <guid>id-unico-123</guid>
            <pubDate>\(fecha)</pubDate>
            <enclosure url="https://ejemplo.test/audio.mp3" length="157286400" type="audio/mpeg"/>
          </item>
        """)
        return RSSParser(feedURL: URL(string: "https://ejemplo.test/feed")).parse(data: xml)?.episodes.first
    }

    // MARK: - Fechas

    /// Cada formato de fecha que no se entienda hace que el episodio se quede con la fecha de
    /// "ahora": parece el más reciente de todos y se cuela el primero en la cola de descargas,
    /// por delante de los que sí son nuevos. De 21 variantes reales, 5 fallaban.
    func testLosFormatosDeFechaRealesSeEntiendenTodos() {
        let casos: [String] = [
            "Tue, 15 Sep 2026 18:15:00 +0200",   // el habitual
            "Wed, 16 Sep 2026 07:00:00 +0000",
            "Wed, 16 Sep 2026 07:00:00 GMT",     // zona con siglas
            "Mon, 14 Sep 2026 09:30:00 -0400",
            "Fri, 11 Sep 2026 12:00:00 PDT",
            "16 Sep 2026 07:00:00 +0000",        // sin día de la semana
            "16 Sep 2026 07:00:00 GMT",
            "Wed, 16 Sep 2026 07:00 +0000",      // sin segundos
            "Wed, 16 Sep 2026 07:00:00",         // sin zona horaria
            "Wed,16 Sep 2026 07:00:00 +0000",    // sin espacio tras la coma
            "2026-09-16T07:00:00Z",              // ISO-8601
            "2026-09-16T07:00:00.000Z",          // con milésimas
            "2026-09-16T07:00:00+02:00",
            "2026-09-16 07:00:00",
            "2026-09-16"
        ]
        // El fallo que hay que cazar es concreto: si el formato no se entiende, el episodio se
        // queda con la fecha de AHORA MISMO. Todas las fechas de la lista son de días concretos de
        // septiembre de 2026, así que ninguna puede salir a menos de una hora del instante actual.
        let ahora = Date()
        for caso in casos {
            guard let episodio = primerEpisodio(fecha: caso) else {
                return XCTFail("No se parseó el feed con la fecha «\(caso)»")
            }
            XCTAssertGreaterThan(abs(episodio.publishedAt.timeIntervalSince(ahora)), 3600,
                                 "La fecha «\(caso)» no se entendió: el episodio se ha quedado con "
                                 + "la hora actual y aparentará ser el más reciente de todos.")
        }
    }

    // MARK: - Contenido del episodio

    func testSeLeeElIdentificadorYElTamanoDelEpisodio() {
        guard let episodio = primerEpisodio(fecha: "Tue, 15 Sep 2026 18:15:00 +0200") else {
            return XCTFail("No se parseó el feed")
        }
        XCTAssertEqual(episodio.guid, "id-unico-123",
                       "Sin el <guid> la identidad vuelve a depender del título")
        XCTAssertEqual(episodio.audioBytes, 157_286_400,
                       "El tamaño es lo único que se le puede decir a iOS sobre la descarga")
        XCTAssertEqual(episodio.audioURL?.absoluteString, "https://ejemplo.test/audio.mp3")
    }

    func testLasURLsSinCifrarSeSubenAHTTPS() {
        let xml = feedXML(item: """
          <item>
            <title>Con http</title>
            <guid>g1</guid>
            <pubDate>Tue, 15 Sep 2026 18:15:00 +0200</pubDate>
            <enclosure url="http://ejemplo.test/audio.mp3" length="100" type="audio/mpeg"/>
          </item>
        """)
        let episodio = RSSParser(feedURL: nil).parse(data: xml)?.episodes.first
        XCTAssertEqual(episodio?.audioURL?.scheme, "https", "iOS bloquea las conexiones sin cifrar")
    }

    func testLosTitulosNoSeQuedanConEntidadesHTMLALaVista() {
        let xml = feedXML(item: """
          <item>
            <title>Tech &amp;amp; Business</title>
            <guid>g1</guid>
            <pubDate>Tue, 15 Sep 2026 18:15:00 +0200</pubDate>
            <enclosure url="https://ejemplo.test/a.mp3" length="100" type="audio/mpeg"/>
          </item>
        """)
        let episodio = RSSParser(feedURL: nil).parse(data: xml)?.episodes.first
        XCTAssertEqual(episodio?.title, "Tech & Business",
                       "El usuario no puede ver «&amp;» literal en el título")
    }

    // MARK: - Feeds rotos

    func testUnFeedSinTituloNoSeAcepta() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><description>Sin título</description></channel></rss>
        """.data(using: .utf8)!
        XCTAssertNil(RSSParser(feedURL: nil).parse(data: xml), "Un feed sin título no es un podcast")
    }

    func testUnXMLBasuraNoRevienta() {
        let basura = "esto no es XML ni de lejos <<<>>>".data(using: .utf8)!
        XCTAssertNil(RSSParser(feedURL: nil).parse(data: basura))
    }

    func testUnEpisodioSinAudioNoRompeElResto() {
        let xml = feedXML(item: """
          <item><title>Sin audio</title><guid>g1</guid>
            <pubDate>Tue, 15 Sep 2026 18:15:00 +0200</pubDate></item>
          <item><title>Con audio</title><guid>g2</guid>
            <pubDate>Tue, 15 Sep 2026 18:15:00 +0200</pubDate>
            <enclosure url="https://ejemplo.test/a.mp3" length="100" type="audio/mpeg"/></item>
        """)
        let episodios = RSSParser(feedURL: nil).parse(data: xml)?.episodes ?? []
        XCTAssertEqual(episodios.count, 2, "Un episodio sin audio no puede costar los demás")
        XCTAssertNotNil(episodios.first { $0.guid == "g2" }?.audioURL)
    }
}
