import AppIntents

/// Acción para la app Atajos: "Refrescar podcasts de Unicast". Pensada para dispararse SIN abrir
/// la app —una automatización nocturna con el iPhone bloqueado—, así que el trabajo real
/// (comprobar que no hay audio sonando, refrescar, registrar el evento) vive en
/// `AppDelegate.onShortcutRefresh`, conectado a la MISMA instancia de la app desde
/// `UnicastApp.init()`, nunca a una copia nueva.
struct RefreshPodcastsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refrescar podcasts de Unicast"
    static var description = IntentDescription("Busca episodios nuevos y los descarga, sin abrir la app.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppDelegate.onShortcutRefresh?()
        return .result()
    }
}

struct UnicastShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshPodcastsIntent(),
                    phrases: ["Refresca podcasts en \(.applicationName)"],
                    shortTitle: "Refrescar podcasts",
                    systemImageName: "arrow.clockwise")
    }
}
