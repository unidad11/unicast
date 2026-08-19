import Foundation
import Observation

/// Descarga el audio de los episodios a disco usando la sesión "en segundo plano" de iOS: la
/// transferencia la gestiona el propio sistema operativo, así que sigue en marcha aunque la app
/// se suspenda o el sistema la mate durante la noche (antes se usaba una `URLSession` normal, que
/// se cortaba en cuanto iOS suspendía la app — por eso solo descargaba de verdad al abrirla a mano).
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()
    static let backgroundSessionIdentifier = "com.jbs.Unicast.downloads"

    /// Episodios que se están descargando ahora mismo.
    var downloading: Set<UUID> = []

    /// Handler que entrega iOS al despertar la app tras terminar descargas en segundo plano;
    /// hay que llamarlo cuando ya se ha procesado todo, para que el sistema sepa que hemos acabado.
    @ObservationIgnored
    var backgroundCompletionHandler: (() -> Void)?

    /// Qué episodio y qué hacer al terminar, para cada tarea de descarga en curso.
    @ObservationIgnored
    private var pending: [Int: (episode: Episode, completion: () -> Void)] = [:]

    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false       // que empiece ya, no cuando iOS lo vea oportuno
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// Fuerza la creación de la sesión en segundo plano (al arrancar o al despertar la app), para
    /// que iOS pueda reengancharnos a descargas que ya estaban en marcha.
    func attachBackgroundSession() {
        _ = session
    }

    /// Carpeta donde vive el audio descargado: Application Support, NO Caches.
    ///
    /// En Caches iOS borra los archivos por su cuenta cuando le falta espacio, y empieza por los
    /// más grandes — o sea, los episodios largos. El episodio seguía marcado como "Descargado"
    /// pero el mp3 ya no estaba, así que al darle al play la app se ponía a hacer streaming sin
    /// avisar: tardaba en arrancar y perdía la posición donde se había quedado.
    private static var audioDirectory: URL {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Que no suba a iCloud: son horas de mp3 y inflaría la copia de seguridad del móvil.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    /// Carpeta antigua (Caches), solo para rescatar lo que quede de versiones anteriores.
    private static var legacyAudioDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
    }

    /// Ruta local donde se guarda el audio de un episodio.
    static func localURL(for episodeID: UUID) -> URL {
        audioDirectory.appendingPathComponent("\(episodeID).mp3")
    }

    /// Pasa a la carpeta nueva los audios que aún queden en la vieja (Caches), para no perder las
    /// descargas que iOS todavía no había borrado. Se llama al arrancar; si no hay nada, no hace nada.
    static func migrateLegacyFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: legacyAudioDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "mp3" {
            let destination = audioDirectory.appendingPathComponent(file.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.moveItem(at: file, to: destination)
        }
    }

    /// ¿El audio ya está descargado en disco?
    static func isDownloaded(_ episodeID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: episodeID).path)
    }

    /// Tamaño en bytes del audio descargado (0 si no está).
    static func fileSize(for episodeID: UUID) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL(for: episodeID).path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    /// Descarga el audio del episodio. Llama a `completion` en el hilo principal, y SOLO si el
    /// archivo llegó a guardarse de verdad (antes se avisaba "Descargado" y se marcaba como tal
    /// aunque la descarga hubiera fallado, dejando el episodio en un estado mentiroso).
    func download(_ episode: Episode, completion: @escaping () -> Void) {
        guard let url = episode.audioURL, !downloading.contains(episode.id) else { return }
        downloading.insert(episode.id)
        let task = session.downloadTask(with: url)
        pending[task.taskIdentifier] = (episode, completion)
        task.resume()
    }

    /// Borra el audio descargado de un episodio (al escucharlo y autoborrarlo, etc.).
    static func deleteFile(for episodeID: UUID) {
        try? FileManager.default.removeItem(at: localURL(for: episodeID))
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    /// iOS borra el archivo temporal en cuanto este método termina, así que hay que moverlo aquí
    /// mismo, sin saltar antes a otro hilo.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let entry = pending[downloadTask.taskIdentifier] else { return }
        let destination = DownloadManager.localURL(for: entry.episode.id)
        try? FileManager.default.removeItem(at: destination)
        let success = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        DispatchQueue.main.async { [weak self] in
            self?.downloading.remove(entry.episode.id)
            self?.pending[downloadTask.taskIdentifier] = nil
            if success {
                Notifications.notifyDownloaded(entry.episode.id, entry.episode.title, podcast: entry.episode.podcastTitle)
                entry.completion()
            }
        }
    }

    /// Si la descarga falla (sin red, error del servidor...), limpia el estado para no dejarla
    /// marcada como "descargando" para siempre.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        DispatchQueue.main.async { [weak self] in
            if let entry = self?.pending[task.taskIdentifier] {
                self?.downloading.remove(entry.episode.id)
            }
            self?.pending[task.taskIdentifier] = nil
        }
    }

    /// Avisa a iOS de que ya hemos terminado de procesar las descargas que despertaron la app.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
