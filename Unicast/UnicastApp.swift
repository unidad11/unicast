import SwiftUI
import BackgroundTasks

/// Punto de entrada de Unicast.
@main
struct UnicastApp: App {
    @State private var store = AppStore.loadOrSample()
    @State private var audioPlayer = AudioPlayer()
    @State private var downloadManager = DownloadManager()
    @State private var colorExtractor = ColorExtractor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(audioPlayer)
                .environment(downloadManager)
                .environment(colorExtractor)
                .preferredColorScheme(.light) // Unicast es clara por diseño (rediseño 2026)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        if let episode = audioPlayer.currentEpisode {
                            let remaining = audioPlayer.duration - audioPlayer.currentTime
                            if audioPlayer.duration > 0, remaining < 40 {
                                store.handleFinished(episode.id)   // autoborrado si faltan <40s
                            } else {
                                store.updatePlaybackPosition(episode.id, audioPlayer.currentTime)
                            }
                        }
                        store.save()
                        scheduleRefresh()   // deja programado un refresco en segundo plano
                    }
                }
                .onAppear {
                    // Recuerda el último episodio (lo deja listo, en pausa).
                    if let episode = store.nowPlaying { audioPlayer.prepare(store.enrich(episode)) }
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
                    // Permiso de notificaciones (aviso de descargas). Se omite en capturas de simulador.
                    if ProcessInfo.processInfo.environment["UNICAST_PREVIEW"] == nil {
                        Notifications.requestPermission()
                    }
                }
        }
        .backgroundTask(.appRefresh("com.jbs.Unicast.refresh")) {
            // iOS ejecuta esto en segundo plano cuando lo cree oportuno: refresca feeds y descarga.
            await store.refresh(downloads: downloadManager)
            scheduleRefresh()
        }
    }

    /// Programa un refresco en segundo plano (iOS decide el momento exacto, best-effort).
    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.jbs.Unicast.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60) // a partir de ~10 min
        try? BGTaskScheduler.shared.submit(request)
    }
}
