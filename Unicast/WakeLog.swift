import Foundation

/// Un despertar de la app para refrescar podcasts: cuándo, por qué vía, y qué consiguió. Existe
/// para poder responder con datos reales, no con sensaciones, a "¿cuántas veces al día me
/// despierta iOS de verdad, y llega a terminar el refresco?".
struct WakeEvent: Codable {
    let date: Date
    let trigger: Trigger
    let podcastsChanged: Int
    let podcastsFailed: Int
    let durationSeconds: Double

    enum Trigger: String, Codable {
        case appRefresh    // BGAppRefreshTask: segundo plano, ventana corta (~30s)
        case processing    // BGProcessingTask: segundo plano, ventana más larga (sin la app abierta)
        case foreground    // la app estaba abierta (al volver a ella o pull-to-refresh)
    }
}

/// Guarda los últimos despertares en un JSON aparte de `unicast_state.json`, para no mezclar
/// datos de diagnóstico con la biblioteca del usuario.
enum WakeLog {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wake_log.json")
    }

    /// Con un despertar cada pocas horas, esto cubre bastante más de dos semanas de historial.
    private static let maxEntries = 300

    static func record(_ event: WakeEvent) {
        var events = load()
        events.append(event)
        if events.count > maxEntries { events.removeFirst(events.count - maxEntries) }
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> [WakeEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([WakeEvent].self, from: data) else { return [] }
        return events
    }
}
