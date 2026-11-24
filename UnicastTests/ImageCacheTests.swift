import XCTest
import UIKit
@testable import Unicast

/// Las carátulas se guardan reducidas y ya decodificadas para que salgan al instante al abrir la app.
final class ImageCacheTests: XCTestCase {

    private func png(lado: Int) -> Data {
        let formato = UIGraphicsImageRendererFormat.default()
        formato.scale = 1
        let imagen = UIGraphicsImageRenderer(size: CGSize(width: lado, height: lado), format: formato).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: lado, height: lado))
        }
        return imagen.pngData()!
    }

    func testUnaImagenGrandeSeReduceAlLadoMaximo() {
        let reducida = ImageCache.reducida(from: png(lado: 2000), maxPixel: 384)
        XCTAssertNotNil(reducida)
        let lado = max(reducida!.size.width * reducida!.scale, reducida!.size.height * reducida!.scale)
        XCTAssertLessThanOrEqual(lado, 384)
        XCTAssertGreaterThan(lado, 300)
    }

    func testUnaImagenPequenaNoSeAgranda() {
        let reducida = ImageCache.reducida(from: png(lado: 100), maxPixel: 384)
        XCTAssertNotNil(reducida)
        let lado = reducida!.size.width * reducida!.scale
        XCTAssertLessThanOrEqual(lado, 384)
    }

    func testDatosQueNoSonUnaImagenDanNil() {
        XCTAssertNil(ImageCache.reducida(from: Data("esto no es una imagen".utf8)))
    }
}
