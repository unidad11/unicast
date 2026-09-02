import UIKit
import BackgroundTasks

/// iOS llama aquí para despertar la app: cuando terminan descargas de la sesión en segundo plano
/// (aunque la app estuviera suspendida o el sistema la hubiera cerrado), y cuando concede la
/// ventana de `BGProcessingTask` — la segunda vía de refresco, con más margen de tiempo que la
/// corta de `BGAppRefreshTask` pero sin el atajo que SwiftUI sí da para esa (`.backgroundTask`
/// no tiene caso para procesamiento, solo para refresco y sesiones URL: hay que registrarla aquí
/// a mano, al estilo de antes de iOS 17).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let processingTaskIdentifier = "com.jbs.Unicast.processing"

    /// Qué hacer cuando iOS concede la ventana de procesamiento. La rellena `UnicastApp` en su
    /// `init` — antes de `.onAppear`, que llega más tarde — para que esté lista en cuanto el
    /// sistema pueda llegar a invocar el handler registrado abajo. Evita crear una segunda copia
    /// del store: reutiliza la misma instancia que ya usa toda la interfaz.
    static var onProcessingTask: (() async -> Void)?

    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // El registro tiene que pasar aquí, antes de que la app termine de lanzarse — si se
        // registra más tarde, iOS lo rechaza en tiempo de ejecución.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            guard let onProcessingTask = Self.onProcessingTask else {
                processingTask.setTaskCompleted(success: false)
                return
            }
            // `setTaskCompleted` no se puede llamar dos veces (crashea) y puede venir tanto del
            // trabajo real como de `expirationHandler` si iOS corta antes de tiempo — de ahí el
            // candado, para que solo la primera llamada cuente.
            let lock = NSLock()
            var completed = false
            let finish: (Bool) -> Void = { success in
                lock.lock()
                let already = completed
                completed = true
                lock.unlock()
                guard !already else { return }
                processingTask.setTaskCompleted(success: success)
            }
            processingTask.expirationHandler = { finish(false) }
            Task { @MainActor in
                await onProcessingTask()
                finish(true)
            }
        }
        return true
    }

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
