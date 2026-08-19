import UIKit

/// iOS llama aquí para despertar la app cuando terminan descargas de la sesión en segundo plano
/// (aunque la app estuviera suspendida o el sistema la hubiera cerrado). Sin esto, las descargas
/// nocturnas de `DownloadManager` no tendrían forma de avisar a iOS de que ya se han procesado.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      handleEventsForBackgroundURLSession identifier: String,
                      completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
        DownloadManager.shared.attachBackgroundSession()
    }
}
