import SwiftUI
import CoreImage
import UIKit

/// Extrae y cachea el color dominante de las portadas para teñir las pantallas (estilo Brink).
/// El color se "suaviza" (más claro y menos saturado) para que combine con el fondo claro
/// y el texto oscuro se siga leyendo bien.
@Observable
final class ColorExtractor {
    private var cache: [String: Color] = [:]
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Color ya calculado para esa portada (nil si aún no está en caché).
    func color(for url: URL?) -> Color? {
        guard let url else { return nil }
        return cache[url.absoluteString]
    }

    /// Descarga la portada y calcula su color dominante si no estaba en caché.
    @MainActor
    func load(_ url: URL?) async {
        guard let url, cache[url.absoluteString] == nil else { return }
        if let color = await Self.dominant(from: url, context: context) {
            cache[url.absoluteString] = color
        }
    }

    private static func dominant(from url: URL, context: CIContext) async -> Color? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              let ci = CIImage(image: image) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent)
        ])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return soften(UIColor(red: CGFloat(pixel[0]) / 255,
                              green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1))
    }

    /// Sube el brillo y baja la saturación para un tinte claro apto para fondo lavanda.
    private static func soften(_ color: UIColor) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        return Color(uiColor: UIColor(hue: h, saturation: min(s, 0.45), brightness: max(br, 0.82), alpha: 1))
    }

    /// Tinte suave a partir de un color hex (respaldo cuando la portada no trae imagen).
    static func soft(hex: String) -> Color {
        soften(UIColor(Color(hex: hex)))
    }
}
