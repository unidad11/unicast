import SwiftUI

/// Sistema de diseño de Unicast: acento, textos, superficies y degradados de fondo.
/// Centraliza los colores para que toda la app tenga la misma cara.
enum Theme {
    /// Acento principal (morado). Identidad de Unicast.
    static let accent = Color(hex: "6B5CE7")
    static let accentLight = Color(hex: "9D8CFF")

    // Textos sobre fondo oscuro
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "8E97AD")
    static let textMuted = Color(hex: "5A627A")

    // Superficies y separadores
    static let surface = Color(hex: "161A24")
    static let surfaceBorder = Color(hex: "232838")
    static let divider = Color(hex: "1A1E2A")

    /// Devuelve el degradado de fondo según el estilo elegido en Ajustes.
    static func background(_ style: BackgroundStyle) -> LinearGradient {
        LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Estilos de degradado de fondo que el usuario puede elegir en Ajustes.
/// (El fondo no es negro plano: un degradado le da vida.)
enum BackgroundStyle: String, CaseIterable, Identifiable, Codable {
    case blueNight, amber, ember, forest, purple, black

    var id: String { rawValue }

    /// Nombre mostrado en la pantalla de Ajustes.
    var displayName: String {
        switch self {
        case .blueNight: "Azul noche"
        case .amber: "Ámbar"
        case .ember: "Brasa"
        case .forest: "Bosque"
        case .purple: "Púrpura"
        case .black: "Negro"
        }
    }

    /// Color de la parte de arriba del degradado.
    var top: Color {
        switch self {
        case .blueNight: Color(hex: "14264F")
        case .amber: Color(hex: "3A2A0A")
        case .ember: Color(hex: "3A1410")
        case .forest: Color(hex: "0C2A1E")
        case .purple: Color(hex: "241640")
        case .black: Color(hex: "0A0A0B")
        }
    }

    /// Color de la parte de abajo (siempre el negro de Unicast).
    var bottom: Color { Color(hex: "0A0A0B") }
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
