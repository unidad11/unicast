import SwiftUI

/// Sistema de diseño de Unicast — tema CLARO/lavanda (rediseño 2026).
/// El morado sigue siendo el acento de identidad.
enum Theme {
    // Acento / identidad
    static let accent = Color(hex: "6B5CE7")
    static let accentDark = Color(hex: "574AC9")
    static let accentLight = Color(hex: "8C7DF2")

    // Textos sobre superficie clara
    static let textPrimary = Color(hex: "1A1622")
    static let textSecondary = Color(hex: "6E6783")
    static let textMuted = Color(hex: "A39DAF")

    // Superficies
    static let surface = Color.white               // tarjetas
    static let surfaceSoft = Color(hex: "F2EFF6")  // chips, fondos internos
    static let surfaceBorder = Color.black.opacity(0.06)
    static let divider = Color.black.opacity(0.07)

    /// Degradado de fondo claro lavanda. (El tinte por podcast se aplica aparte.)
    static func background(_ style: BackgroundStyle = .lavender) -> LinearGradient {
        LinearGradient(colors: [Color(hex: "DAD5E3"), Color(hex: "C7BFD8")],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Degradado del fondo teñido con el color de un podcast (cabeceras, reproductor).
    static func tinted(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.55), Color(hex: "DAD5E3")],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Estilos de fondo (de momento el tema es claro fijo; se conserva el enum para el selector
/// de Ajustes, que se replanteará en la fase de pulido del rediseño).
enum BackgroundStyle: String, CaseIterable, Identifiable, Codable {
    case lavender, blueNight, amber, ember, forest, purple, black

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lavender: "Lavanda"
        case .blueNight: "Azul noche"
        case .amber: "Ámbar"
        case .ember: "Brasa"
        case .forest: "Bosque"
        case .purple: "Púrpura"
        case .black: "Negro"
        }
    }

    var top: Color {
        switch self {
        case .lavender: Color(hex: "DAD5E3")
        case .blueNight: Color(hex: "14264F")
        case .amber: Color(hex: "3A2A0A")
        case .ember: Color(hex: "3A1410")
        case .forest: Color(hex: "0C2A1E")
        case .purple: Color(hex: "241640")
        case .black: Color(hex: "0A0A0B")
        }
    }

    var bottom: Color { Color(hex: "C7BFD8") }
}

extension Color {
    /// Crea un color a partir de un hex tipo "RRGGBB" (con o sin almohadilla).
    init(hex: String) {
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: clean)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
