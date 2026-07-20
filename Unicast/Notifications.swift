import Foundation
import UserNotifications

/// Notificaciones locales: aviso cuando se descarga un episodio nuevo (punto 22).
enum Notifications {
    /// Pide permiso para notificar (una vez, al arrancar).
    static func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Avisa de que un episodio se acaba de descargar.
    static func notifyDownloaded(_ episodeID: UUID, _ episodeTitle: String, podcast: String) {
        let content = UNMutableNotificationContent()
        content.title = podcast
        content.body = "Descargado: \(episodeTitle)"
        content.sound = .default
        content.userInfo = ["episodeID": episodeID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Al tocar la notificación de "episodio descargado", lo reproduce directamente (como Overcast).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var store: AppStore?
    var audioPlayer: AudioPlayer?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let idString = response.notification.request.content.userInfo["episodeID"] as? String,
              let episodeID = UUID(uuidString: idString),
              let store, let audioPlayer,
              let episode = store.episode(id: episodeID) else { return }
        let enriched = store.enrich(episode)
        store.nowPlaying = enriched
        audioPlayer.play(enriched)
        store.isPlayerPresented = true
    }

    /// Muestra la notificación también si la app ya está abierta en primer plano.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
