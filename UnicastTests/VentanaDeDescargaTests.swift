import XCTest
@testable import Unicast

/// Qué se baja solo y qué no. Es la promesa central de la app: "tener los últimos episodios
/// listos sin hacer nada".
@MainActor
final class VentanaDeDescargaTests: XCTestCase {

    private func episodio(_ titulo: String, diasAtras: Int, descargado: Bool = false,
                          escuchado: Bool = false, aMano: Bool = false) -> Episode {
        Episode(title: titulo, podcastTitle: "P", colorHex: "FFFFFF",
                audioURL: URL(string: "https://ejemplo.test/a.mp3"), duration: 100,
                publishedAt: Date(timeIntervalSinceNow: -Double(diasAtras) * 86400),
                isDownloaded: descargado, isPlayed: escuchado, manuallyDownloaded: aMano)
    }

    private func store(_ episodios: [Episode], limite: DownloadLimit = .last(5),
                       desde: Date? = nil) -> AppStore {
        let store = AppStore()
        store.podcasts = [Podcast(title: "P", author: "A", colorHex: "FFFFFF",
                                  episodes: episodios, downloadLimit: limite, downloadFromDate: desde)]
        return store
    }

    // MARK: - La ventana

    func testSoloEntranLosUltimosSegunElLimiteDelPodcast() {
        let episodios = (0..<20).map { episodio("Cap \($0)", diasAtras: $0) }
        let s = store(episodios, limite: .last(5), desde: Date(timeIntervalSinceNow: -100 * 86400))
        XCTAssertEqual(s.autoDownloadWindow(for: s.podcasts[0]).count, 5)
    }

    func testNoSeBajaElHistoricoAnteriorAlAlta() {
        let episodios = (0..<20).map { episodio("Cap \($0)", diasAtras: $0) }
        // Alta hace 3 días: solo los publicados desde entonces.
        let s = store(episodios, limite: .all, desde: Date(timeIntervalSinceNow: -3 * 86400))
        let ventana = s.autoDownloadWindow(for: s.podcasts[0])
        XCTAssertLessThanOrEqual(ventana.count, 4,
                                 "Seguir un podcast no puede bajar sus 20 años de archivo")
    }

    func testElLimiteTodosNoSeSaltaLaFechaDeAlta() {
        let episodios = (0..<50).map { episodio("Cap \($0)", diasAtras: $0) }
        let s = store(episodios, limite: .all, desde: Date(timeIntervalSinceNow: -10 * 86400))
        XCTAssertLessThanOrEqual(s.autoDownloadWindow(for: s.podcasts[0]).count, 11)
    }

    /// Fallo real: seguir un podcast recién estrenado fijaba el corte en "ahora mismo", así que su
    /// primer capítulo, publicado unas horas antes, quedaba fuera para siempre.
    func testUnPodcastSinEpisodiosNoSeCierraALoQueVengaDespues() {
        let s = store([], limite: .last(5), desde: nil)
        let corte = s.effectiveDownloadFrom(s.podcasts[0])
        XCTAssertLessThan(corte, Date(timeIntervalSinceNow: -86400),
                          "El corte no puede ser «ahora»: dejaría fuera el primer capítulo")
    }

    // MARK: - Qué queda pendiente

    func testLoPendienteEsLoQueFaltaPorBajar() {
        let episodios = (0..<10).map { episodio("Cap \($0)", diasAtras: $0) }
        let s = store(episodios, limite: .last(3), desde: Date(timeIntervalSinceNow: -100 * 86400))
        XCTAssertEqual(s.pendingDownloads().count, 3)
    }

    func testLoEscuchadoNoCuentaComoPendiente() {
        var episodios = (0..<3).map { episodio("Cap \($0)", diasAtras: $0) }
        episodios[0].isPlayed = true
        let s = store(episodios, limite: .last(5), desde: Date(timeIntervalSinceNow: -100 * 86400))
        XCTAssertEqual(s.pendingDownloads().count, 2)
    }

    func testUnPodcastConLaAutoDescargaApagadaNoPideNada() {
        let episodios = (0..<5).map { episodio("Cap \($0)", diasAtras: $0) }
        let s = AppStore()
        s.podcasts = [Podcast(title: "P", author: "A", colorHex: "FFFFFF", episodes: episodios,
                              autoDownload: false, downloadFromDate: Date(timeIntervalSinceNow: -100 * 86400))]
        XCTAssertTrue(s.pendingDownloads().isEmpty)
    }

    // MARK: - Volver a poner un episodio como pendiente

    /// "Escuchado" era un camino de ida sin vuelta: nada en toda la app lo devolvía atrás, así que
    /// un episodio descartado por error no se volvía a descargar nunca.
    func testSePuedeDevolverUnEpisodioAPendiente() {
        var episodios = [episodio("Cap 0", diasAtras: 0, escuchado: true)]
        episodios[0].downloadFailures = 3
        let s = store(episodios, limite: .last(5), desde: Date(timeIntervalSinceNow: -100 * 86400))
        XCTAssertTrue(s.pendingDownloads().isEmpty)

        s.markUnplayed(episodios[0].id, in: s.podcasts[0].id)

        XCTAssertEqual(s.pendingDownloads().count, 1, "Vuelve a la cola de descarga")
        XCTAssertEqual(s.podcasts[0].episodes[0].downloadFailures, 0, "Y sin arrastrar la espera")
    }

    // MARK: - Los ajustes por podcast tienen que hacer algo

    func testBorrarAlTerminarApagadoConservaElAudio() {
        let uno = episodio("Cap 0", diasAtras: 0, descargado: true)
        let s = AppStore()
        s.podcasts = [Podcast(title: "P", author: "A", colorHex: "FFFFFF", episodes: [uno],
                              autoDeleteOnFinish: false)]
        s.handleFinished(uno.id)
        XCTAssertTrue(s.podcasts[0].episodes[0].isDownloaded, "Se pidió NO borrar al terminar")
        XCTAssertTrue(s.podcasts[0].episodes[0].isPlayed, "Pero sí queda marcado como escuchado")
    }

    func testBorrarAlTerminarEncendidoSiQuitaElAudio() {
        let uno = episodio("Cap 0", diasAtras: 0, descargado: true)
        let s = AppStore()
        s.podcasts = [Podcast(title: "P", author: "A", colorHex: "FFFFFF", episodes: [uno],
                              autoDeleteOnFinish: true)]
        s.handleFinished(uno.id)
        XCTAssertFalse(s.podcasts[0].episodes[0].isDownloaded)
        XCTAssertTrue(s.podcasts[0].episodes[0].isPlayed)
    }

    func testElLimitePorDefectoSeAplicaAUnPodcastNuevo() {
        let s = AppStore()
        s.defaultDownloadLimit = .last(10)
        s.subscribe(Podcast(title: "Nuevo", author: "A", colorHex: "FFFFFF",
                            episodes: (0..<20).map { episodio("Cap \($0)", diasAtras: $0) }),
                    downloads: DownloadManager.shared)
        XCTAssertEqual(s.podcasts.first?.downloadLimit, .last(10),
                       "El ajuste «Guardar por defecto» tiene que servir para algo")
    }
}
