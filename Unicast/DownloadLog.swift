import Foundation

/// Cada descarga, con la hora en que se ENCOLÓ y la hora en que terminó.
///
/// Existe para responder a la única pregunta que quedaba abierta tras siete rondas de arreglos:
/// cuando un episodio nuevo aparece a la 1:00 de la madrugada y el mp3 no está en el móvil hasta
/// las 7:00, ¿es que la app no llegó a pedir la descarga, o es que iOS la pidió a la 1:00 y el
/// sistema la tuvo aparcada seis horas? La fecha del archivo en disco solo cuenta cuándo TERMINÓ,
/// así que las dos explicaciones eran indistinguibles y se estaba discutiendo a ciegas.
///
/// Con "encolada 01:00 · terminada 07:12" delante, la respuesta deja de ser una teoría.
struct DownloadEvent: Codable, Identifiable {
    let episodeID: UUID
    let title: String
    let podcastTitle: String
    /// Cuándo se le pidió la descarga a iOS.
    let queuedAt: Date
    /// En qué estado estaba la app al pedirla. Es la diferencia que lo decide todo: iOS solo
    /// respeta "empieza ya" si la transferencia se pide con la app en primer plano.
    let foreground: Bool
    /// Bytes que anunciaba el feed (nil si el feed no lo decía).
    let expectedBytes: Int64?
    /// Cuándo terminó, si terminó.
    var finishedAt: Date?
    /// Qué pasó al final: nil mientras sigue en marcha.
    var outcome: String?
    /// Bytes que realmente se guardaron.
    var actualBytes: Int64?

    var id: UUID { episodeID }

    /// Cuánto estuvo iOS con la descarga entre manos, en segundos. Este es EL número.
    var waitSeconds: Double? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(queuedAt)
    }
}

/// Guarda los últimos eventos de descarga en un JSON aparte, igual que `WakeLog`.
enum DownloadLog {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("download_log.json")
    }

    /// Con unas pocas descargas al día, esto cubre de sobra un par de semanas.
    private static let maxEntries = 200

    /// Acceso serializado: al delegado de URLSession lo llama iOS desde una cola de fondo, y el
    /// encolado puede venir del hilo principal. Sin esto, dos escrituras a la vez se pisarían.
    private static let queue = DispatchQueue(label: "com.jbs.Unicast.downloadlog")

    /// Apunta que se acaba de pedir una descarga.
    static func queued(_ event: DownloadEvent) {
        queue.sync {
            var events = loadUnsafe()
            // Si ese episodio ya estaba apuntado sin terminar, se sustituye: es un reintento.
            events.removeAll { $0.episodeID == event.episodeID && $0.finishedAt == nil }
            events.append(event)
            saveUnsafe(events)
        }
    }

    /// Cierra el evento abierto de ese episodio con lo que haya pasado.
    static func finished(_ episodeID: UUID, outcome: String, bytes: Int64?) {
        queue.sync {
            var events = loadUnsafe()
            guard let index = events.lastIndex(where: { $0.episodeID == episodeID && $0.finishedAt == nil })
            else { return }
            events[index].finishedAt = Date()
            events[index].outcome = outcome
            events[index].actualBytes = bytes
            saveUnsafe(events)
        }
    }

    static func load() -> [DownloadEvent] { queue.sync { loadUnsafe() } }

    // MARK: - Sin candado (solo desde dentro de `queue`)

    private static func loadUnsafe() -> [DownloadEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([DownloadEvent].self, from: data) else { return [] }
        return events
    }

    private static func saveUnsafe(_ events: [DownloadEvent]) {
        var events = events
        if events.count > maxEntries { events.removeFirst(events.count - maxEntries) }
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
