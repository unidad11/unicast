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
    static func notifyDownloaded(_ episodeTitle: String, podcast: String) {
        let content = UNMutableNotificationContent()
        content.title = podcast
        content.body = "Descargado: \(episodeTitle)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
