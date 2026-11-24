import XCTest
@testable import Unicast

/// La «Selección de Claude»: lo que se puede comprobar sin red (lectura de la selección, dirección y huella).
@MainActor
final class ClaudePicksTests: XCTestCase {

    func testLeeLaSeleccionQueDevuelveElMacMini() throws {
        let json = """
        {"generado": 1790000000000, "hash": "abc", "idioma": "ES", "fuentes": ["https://ejemplo.es"],
         "items": [{"id": 123, "title": "Hard Fork", "author": "NYT", "artwork": "https://x/a.jpg",
                    "feed": "https://x/feed", "genre": "Tecnología", "episodes": 200,
                    "lastRelease": "2026-11-20T10:00:00Z", "reason": "Como Emilcar Daily pero en inglés",
                    "basedOn": ["Emilcar Daily"]}]}
        """
        let seleccion = try JSONDecoder().decode(ClaudeSelection.self, from: Data(json.utf8))
        XCTAssertEqual(seleccion.items.count, 1)
        XCTAssertEqual(seleccion.items[0].title, "Hard Fork")
        XCTAssertEqual(seleccion.items[0].searchResult.collectionName, "Hard Fork")
        XCTAssertEqual(seleccion.items[0].searchResult.feed?.absoluteString, "https://x/feed")
    }

    func testLimpiarLaDireccion() {
        XCTAssertEqual(ClaudePicksService.limpiar("  ejemplo.ts.net/ "), "https://ejemplo.ts.net")
        XCTAssertEqual(ClaudePicksService.limpiar("http://192.168.1.5:5121"), "http://192.168.1.5:5121")
        XCTAssertEqual(ClaudePicksService.limpiar("   "), "")
    }

    func testLaHuellaNoDependeDelOrdenNiDeLoEscuchado() {
        let a = Podcast(title: "A", author: "x", colorHex: "FFFFFF")
        let b = Podcast(title: "B", author: "x", colorHex: "FFFFFF")
        XCTAssertEqual(ClaudePicksService.huella([a, b], idioma: "ES"), ClaudePicksService.huella([b, a], idioma: "ES"))
        XCTAssertNotEqual(ClaudePicksService.huella([a, b], idioma: "ES"), ClaudePicksService.huella([a, b], idioma: "US"))
        XCTAssertNotEqual(ClaudePicksService.huella([a], idioma: "ES"), ClaudePicksService.huella([a, b], idioma: "ES"))
    }
}
