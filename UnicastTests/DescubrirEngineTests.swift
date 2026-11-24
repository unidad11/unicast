import XCTest
@testable import Unicast

/// Descubrir: la parte que no necesita internet (palabras clave, categoría, comparación de nombres y feeds).
final class DescubrirEngineTests: XCTestCase {

    func testLasPalabrasClaveIgnoranVaciasYEtiquetas() {
        let textos = [
            "<p>Historia de Roma y del imperio romano. Episodios cada semana.</p>",
            "Roma, imperios y batallas. Escucha el podcast en https://ejemplo.com/roma",
        ]
        let claves = DescubrirEngine.palabrasClave(de: textos, excluyendo: ["Historia"])
        XCTAssertFalse(claves.isEmpty)
        XCTAssertFalse(claves.contains("podcast"))
        XCTAssertFalse(claves.contains("historia"))
        XCTAssertFalse(claves.contains("ejemplo"))
    }

    func testNormalizarIgnoraTildesMayusculasYSignos() {
        XCTAssertEqual(DescubrirEngine.normalizar("La Escóbula de la Brújula!"), "laescobuladelabrujula")
    }

    func testNormalizarFeedIgnoraProtocoloYBarraFinal() {
        XCTAssertEqual(DescubrirEngine.normalizarFeed("HTTPS://www.Ejemplo.com/feed/"), "ejemplo.com/feed")
        XCTAssertEqual(DescubrirEngine.normalizarFeed("http://ejemplo.com/feed"), "ejemplo.com/feed")
    }

    func testLosPaisesDependenDelIdioma() {
        XCTAssertEqual(DescubrirEngine.paises(idioma: "ES").map(\.code), ["es", "mx", "ar"])
        XCTAssertEqual(DescubrirEngine.paises(idioma: "US").map(\.code), ["us", "gb"])
    }
}
