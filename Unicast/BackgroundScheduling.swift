import Foundation
import BackgroundTasks

/// Pide a iOS las "citas" en segundo plano y deja constancia de cómo fue cada intento.
///
/// Antes esto se hacía con `try?` delante, así que un rechazo del sistema no lo veía nadie: la app
/// creía haber pedido el refresco nocturno sin saber si iOS lo había aceptado.
///
/// (Aquí decía que el bundle no declaraba `fetch` ni `processing` y que por eso fallaba todo. Es
/// FALSO: se comprobó compilando con y sin el ajuste acusado y el .app declara los tres modos en
/// los dos casos. El verdadero motivo de que no hubiera refresco nocturno era que nadie pedía la
/// siguiente cita al terminar una tarea, y eso está arreglado en `UnicastApp`.)
///
/// El registro va a UserDefaults, no al JSON de la biblioteca: hay que poder consultarlo en
/// Ajustes aunque el intento haya ocurrido en un arranque en segundo plano, sin pantalla ninguna.
enum BackgroundScheduling {
    static let refreshIdentifier = "com.jbs.Unicast.refresh"
    static let processingIdentifier = "com.jbs.Unicast.processing"

    /// Cómo fue el último intento de pedir una cita, para un identificador concreto.
    struct Attempt: Codable, Identifiable {
        let date: Date
        let identifier: String
        /// nil = iOS la aceptó. Si no, el motivo en cristiano.
        let failure: String?

        var succeeded: Bool { failure == nil }

        /// Solo se guarda un intento por identificador, así que sirve de id.
        var id: String { identifier }
    }

    private static let storageKey = "unicast.background.lastAttempts"

    /// Pide las dos citas: la corta (`BGAppRefreshTask`, ~30 s) y la larga (`BGProcessingTask`).
    /// Ninguna tiene hora garantizada; son dos oportunidades en vez de una.
    static func scheduleAll() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)   // a partir de ~10 min
        submit(refresh)

        // A la larga se le pide SOLO red: exigir batería o cargador reduciría todavía más las
        // oportunidades de que iOS llegue a concederla.
        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        submit(processing)
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
            record(Attempt(date: Date(), identifier: request.identifier, failure: nil))
        } catch {
            record(Attempt(date: Date(), identifier: request.identifier, failure: describe(error)))
        }
    }

    /// Traduce el error de `BGTaskScheduler` a algo que se pueda leer en la pantalla de Ajustes.
    /// Se comparan los códigos a mano (1/2/3) en vez de usar el enum de Apple para no depender de
    /// cómo se llame en cada versión del SDK.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == "BGTaskSchedulerErrorDomain" else { return ns.localizedDescription }
        switch ns.code {
        case 1:
            return "iOS no lo permite ahora mismo: suele ser el modo de bajo consumo, o "
                 + "«Actualización en segundo plano» apagada en Ajustes."
        case 2:
            return "Había demasiadas peticiones pendientes a la vez."
        case 3:
            return "La app no tiene declarada esta tarea en su configuración (Info.plist)."
        default:
            return ns.localizedDescription
        }
    }

    // MARK: - Registro

    private static func record(_ attempt: Attempt) {
        var latest = byIdentifier()
        latest[attempt.identifier] = attempt   // solo interesa el último intento de cada una
        guard let data = try? JSONEncoder().encode(latest) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func byIdentifier() -> [String: Attempt] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([String: Attempt].self, from: data) else { return [:] }
        return stored
    }

    /// Último intento de cada cita, el más reciente primero.
    static var lastAttempts: [Attempt] {
        byIdentifier().values.sorted { $0.date > $1.date }
    }

    // MARK: - Lo que declara el bundle

    /// Modos de segundo plano que declara la app YA INSTALADA (no el Info.plist del repositorio).
    /// Es la comprobación que habría cantado el bug desde el primer día: aquí solo aparecía
    /// "audio" porque un ajuste del proyecto pisaba la lista entera del Info.plist.
    static var declaredBackgroundModes: [String] {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []
    }

    /// Identificadores de tarea que iOS nos deja pedir (también del bundle instalado).
    static var permittedIdentifiers: [String] {
        (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]) ?? []
    }

    /// ¿Está todo lo necesario declarado para que iOS pueda despertar la app?
    static var bundleIsCorrectlyDeclared: Bool {
        let modes = Set(declaredBackgroundModes)
        let identifiers = Set(permittedIdentifiers)
        return modes.contains("fetch") && modes.contains("processing")
            && identifiers.contains(refreshIdentifier) && identifiers.contains(processingIdentifier)
    }
}
