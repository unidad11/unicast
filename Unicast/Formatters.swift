import SwiftUI

/// Formatea una duración en segundos como "1 h 12 min" o "48 min".
func formatDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int(seconds / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 { return "\(hours) h \(String(format: "%02d", minutes)) min" }
    return "\(minutes) min"
}

/// Devuelve "Hoy", "Ayer", el día de la semana o "d MMM" según cuándo se publicó.
func relativeDay(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Hoy" }
    if cal.isDateInYesterday(date) { return "Ayer" }
    let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "es_ES")
    formatter.dateFormat = days < 7 ? "EEE" : "d MMM"
    return formatter.string(from: date).capitalized
}

/// Fuente con carácter para los nombres de podcast (aproximación a la "cómic" del diseño,
/// usando una fuente ya incluida en iOS para no añadir recursos todavía).
/// Cuando queramos la tipografía exacta (Bangers), se añadirá como recurso del bundle.
func displayFont(size: CGFloat) -> Font {
    Font.custom("MarkerFelt-Wide", size: size)
}

/// Formatea segundos como reloj "9:32" o "1:09:32".
func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
}
