import SwiftUI
import BackgroundTasks
import UserNotifications

/// Punto de entrada de Unicast.
@main
struct UnicastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.loadOrSample()
    @State private var audioPlayer = AudioPlayer()
    @State private var downloadManager = DownloadManager.shared
    @State private var colorExtractor = ColorExtractor()
    @State private var notificationDelegate = NotificationDelegate()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGProcessingTask no tiene atajo en SwiftUI (`.backgroundTask` solo cubre refresco y
        // sesiones URL), así que su handler vive en AppDelegate — sin @Environment ahí, se le
        // pasa el trabajo por esta closure. `store`/`downloadManager` ya están inicializados en
        // este punto (son @State con valor por defecto): se captura la MISMA instancia que usará
        // el resto de la app, nunca una copia nueva.
        let store = store
        let downloadManager = downloadManager
        AppDelegate.onProcessingTask = {
            let start = Date()
            let summary = await store.refresh(downloads: downloadManager)
            WakeLog.record(WakeEvent(date: start, trigger: .processing,
                                      podcastsChanged: summary.changed, podcastsFailed: summary.failed,
                                      durationSeconds: Date().timeIntervalSince(start)))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(audioPlayer)
                .environment(downloadManager)
                .environment(colorExtractor)
                .preferredColorScheme(.light) // Unicast es clara por diseño (rediseño 2026)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        // Al volver a la app: refresco automático (si el último tiene >5 min).
                        // @MainActor: evita que este refresco se cruce con un "seguir podcast" a la vez.
                        Task { @MainActor in
                            let start = Date()
                            guard let summary = await store.refreshIfStale(downloads: downloadManager) else { return }
                            WakeLog.record(WakeEvent(date: start, trigger: .foreground,
                                                      podcastsChanged: summary.changed, podcastsFailed: summary.failed,
                                                      durationSeconds: Date().timeIntervalSince(start)))
                        }
                    } else {
                        if let episode = audioPlayer.currentEpisode {
                            let remaining = audioPlayer.duration - audioPlayer.currentTime
                            if audioPlayer.duration > 0, remaining < 40 {
                                store.handleFinished(episode.id)   // autoborrado si faltan <40s
                            } else {
                                store.updatePlaybackPosition(episode.id, audioPlayer.currentTime)
                            }
                        }
                        store.save()
                        // Dos vías de refresco en segundo plano, no una: `scheduleRefresh` es la
                        // ventana corta (~30s) de siempre; `scheduleProcessing` es más larga pero
                        // iOS tiende a reservarla para cuando el móvil está quieto. Ninguna de las
                        // dos tiene hora garantizada — solo son dos oportunidades en vez de una.
                        scheduleRefresh()
                        scheduleProcessing()
                    }
                }
                .onAppear {
                    // Conecta ya la sesión de descargas en segundo plano (por si había alguna en
                    // marcha de la noche anterior que necesite avisar a la app de que terminó).
                    downloadManager.attachBackgroundSession()
                    // Una descarga puede terminar con la app cerrada; entonces no hay ninguna
                    // pantalla esperando para apuntarlo y hay que marcarlo aquí.
                    downloadManager.onFinished = { id in
                        store.markDownloaded(id)
                        store.save()
                    }
                    // Rescata el audio que quede en la carpeta vieja y, después, comprueba qué
                    // descargas se ha llevado iOS por delante (vuelve a bajar las empezadas).
                    DownloadManager.migrateLegacyFiles()
                    DownloadManager.cleanUpInvalidFiles()   // restos de descargas fallidas
                    // Huérfanos: audio bien descargado que se quedó sin episodio porque un
                    // refresco se cortó a mitad. Los que están descargándose AHORA se excluyen
                    // (siguen en la lista aunque su fichero final aún no exista o esté a medias).
                    let validIDs = Set(store.podcasts.flatMap { $0.episodes.map(\.id) })
                        .union(downloadManager.downloading)
                    DownloadManager.cleanUpOrphans(validEpisodeIDs: validIDs)
                    store.reconcileDownloads(using: downloadManager)
                    // Recuerda el último episodio (lo deja listo, en pausa).
                    if let episode = store.nowPlaying { audioPlayer.prepare(store.enrich(episode)) }
                    // Guarda la posición al pausar y cada poco mientras suena. Antes solo se
                    // guardaba al salir de la app, así que un cierre inesperado perdía el sitio.
                    audioPlayer.onPositionUpdate = { id, time in
                        store.updatePlaybackPosition(id, time)
                        store.save()
                    }
                    // Reproducción continua + autoborrado al terminar.
                    audioPlayer.onFinished = { id in
                        let next = store.nextEpisode(after: id)
                        store.handleFinished(id)
                        if let next {
                            let ep = store.enrich(next)
                            store.nowPlaying = ep
                            audioPlayer.play(ep)
                        }
                    }
                    // Al tocar la notificación de descarga, reproduce ese episodio (como Overcast).
                    notificationDelegate.store = store
                    notificationDelegate.audioPlayer = audioPlayer
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                    // Permiso de notificaciones (aviso de descargas). Se omite en capturas de simulador.
                    if ProcessInfo.processInfo.environment["UNICAST_PREVIEW"] == nil {
                        Notifications.requestPermission()
                    }
                }
        }
        .backgroundTask(.appRefresh("com.jbs.Unicast.refresh")) {
            // iOS ejecuta esto en segundo plano cuando lo cree oportuno: refresca feeds y descarga.
            await refreshInBackground(trigger: .appRefresh)
        }
    }

    /// Programa un refresco corto en segundo plano (iOS decide el momento exacto, best-effort).
    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.jbs.Unicast.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60) // a partir de ~10 min
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Programa la vía más larga (BGProcessingTask): iOS la ejecuta con menos prisa, típicamente
    /// cuando detecta el dispositivo ocioso, así que le pedimos solo red — no batería ni carga,
    /// para no reducir encima las oportunidades de que llegue a ejecutarse.
    private func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: "com.jbs.Unicast.processing")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// @MainActor: el refresco en segundo plano toca `store.podcasts` igual que "seguir un podcast";
    /// forzarlo al hilo principal evita que ambas cosas se crucen y se pisen entre sí.
    @MainActor
    private func refreshInBackground(trigger: WakeEvent.Trigger) async {
        let start = Date()
        let summary = await store.refresh(downloads: downloadManager)
        WakeLog.record(WakeEvent(date: start, trigger: trigger,
                                  podcastsChanged: summary.changed, podcastsFailed: summary.failed,
                                  durationSeconds: Date().timeIntervalSince(start)))
        scheduleRefresh()
        scheduleProcessing()
    }
}
