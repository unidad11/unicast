import SwiftUI

/// Punto de entrada de Unicast.
///
/// Por ahora la app arranca con datos de ejemplo para poder ver la interfaz.
/// La capa de feeds RSS, descargas y persistencia se conectará en fases posteriores
/// (el `AppStore` ya está pensado para que las vistas no cambien cuando eso ocurra).
@main
struct UnicastApp: App {
    /// Estado global de la app (biblioteca, listas, reproductor, ajustes).
    @State private var store = AppStore.loadOrSample()
    @State private var audioPlayer = AudioPlayer()
    @State private var downloadManager = DownloadManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(audioPlayer)
                .environment(downloadManager)
                .preferredColorScheme(.dark) // Unicast es oscura por diseño
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
                    }
                }
                .onAppear {
                    // Recuerda el último episodio (lo deja listo, en pausa).
                    if let episode = store.nowPlaying { audioPlayer.prepare(store.enrich(episode)) }
                    // Autoborrado al terminar.
                    audioPlayer.onFinished = { id in
                        let next = store.nextEpisode(after: id)   // reproducción continua (punto 5)
                        store.handleFinished(id)
                        if let next {
                            let ep = store.enrich(next)
                            store.nowPlaying = ep
                            audioPlayer.play(ep)
                        }
                    }
                    // Permiso de notificaciones (aviso de descargas).
                    Notifications.requestPermission()
                }
        }
    }
}
