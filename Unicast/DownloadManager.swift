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

    /// Aviso de "este episodio ya está en disco". Hace falta además de la `completion` de abajo
    /// porque, si la descarga terminó con la app cerrada, no queda ninguna `completion` viva.
    @ObservationIgnored
    var onFinished: ((UUID) -> Void)?

    /// Qué hacer al terminar, para cada tarea de descarga lanzada con la app abierta.
    @ObservationIgnored
    private var pending: [Int: () -> Void] = [:]

    /// Ficha que se apunta en la propia tarea de descarga (`taskDescription`). iOS la guarda junto
    /// a la transferencia, así que sobrevive a que la app se cierre: es lo único que permite saber
    /// de qué episodio era un archivo que terminó de bajarse de madrugada.
    private struct TaskInfo: Codable {
        let id: UUID
        let title: String
        let podcastTitle: String
    }

    private static func encode(_ info: TaskInfo) -> String? {
        guard let data = try? JSONEncoder().encode(info) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ description: String?) -> TaskInfo? {
        guard let data = description?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskInfo.self, from: data)
    }

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
    /// que iOS pueda reengancharnos a descargas que ya estaban en marcha, y repuebla la lista de
    /// "descargando ahora" preguntándole al sistema qué sigue en vuelo. Sin esto, al reabrir la app
    /// las descargas en curso no mostraban la ruedecita y se podían encolar dos veces.
    func attachBackgroundSession() {
        session.getAllTasks { tasks in
            let ids = tasks.compactMap { Self.decode($0.taskDescription)?.id }
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                for id in ids { self?.downloading.insert(id) }
            }
        }
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

    /// Por debajo de esto no es un episodio: es la página de error del servidor guardada con
    /// extensión .mp3. En el iPhone había seis archivos de 77 bytes haciéndose pasar por audio.
    private static let minimumValidSize: Int64 = 32 * 1024

    /// Barre los restos de descargas fallidas: archivos .mp3 demasiado pequeños para ser un
    /// episodio (páginas de error del servidor que se guardaron con extensión de audio). Se llama
    /// al arrancar; si no hay ninguno, no hace nada.
    ///
    /// Solo mira archivos ya completos: los que están bajándose viven en la carpeta temporal de
    /// iOS y no llegan aquí hasta que terminan, así que no se puede cortar una descarga en curso.
    static func cleanUpInvalidFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "mp3" {
            let attributes = try? fm.attributesOfItem(atPath: file.path)
            let size = (attributes?[.size] as? Int64) ?? 0
            if size < minimumValidSize { try? fm.removeItem(at: file) }
        }
    }

    /// Borra los .mp3 en disco que no corresponden a NINGÚN episodio de la biblioteca actual:
    /// audio que se llegó a descargar bien pero se quedó sin dueño porque el refresco que lo
    /// disparó se cortó antes de guardar la asociación (el caso de las descargas en segundo plano
    /// que no llegaban a terminar de fusionarse). Sin id no hay forma de saber a qué pertenecían,
    /// así que no se pueden recuperar: solo limpiar el espacio que ocupan.
    static func cleanUpOrphans(validEpisodeIDs: Set<UUID>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "mp3" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !validEpisodeIDs.contains(id) else { continue }
            try? fm.removeItem(at: file)
        }
    }

    /// ¿El audio ya está descargado en disco? Un archivo ridículamente pequeño NO cuenta: se da
    /// por no descargado para que se vuelva a bajar en condiciones.
    static func isDownloaded(_ episodeID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: episodeID).path)
            && fileSize(for: episodeID) >= minimumValidSize
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
        // La identidad del episodio viaja DENTRO de la tarea, no solo en memoria: es lo que hace
        // que una descarga terminada de madrugada se pueda guardar en su sitio al despertar.
        task.taskDescription = Self.encode(TaskInfo(id: episode.id,
                                                    title: episode.title,
                                                    podcastTitle: episode.podcastTitle))
        pending[task.taskIdentifier] = completion
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
        // El episodio se saca de la ficha de la tarea, NO de `pending`. Antes se leía de `pending`,
        // que solo vive en memoria: cuando iOS terminaba una descarga con la app cerrada (el caso
        // de las descargas nocturnas), esa lista estaba vacía y el archivo recién bajado se
        // descartaba aquí mismo. Se gastaban los datos y el episodio seguía sin descargar.
        guard let info = Self.decode(downloadTask.taskDescription) else { return }
        // Un 404 o un "servidor caído" también llega hasta aquí, con la página de error como
        // contenido. Sin esta comprobación se guardaba como si fuera el episodio y quedaba
        // marcado "Descargado" un archivo de 77 bytes que no suena.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        guard (200...299).contains(status), size >= Self.minimumValidSize else {
            DispatchQueue.main.async { [weak self] in
                self?.downloading.remove(info.id)
                self?.pending[downloadTask.taskIdentifier] = nil
            }
            return
        }
        let destination = DownloadManager.localURL(for: info.id)
        try? FileManager.default.removeItem(at: destination)
        let success = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downloading.remove(info.id)
            let completion = self.pending.removeValue(forKey: downloadTask.taskIdentifier)
            guard success else { return }
            Notifications.notifyDownloaded(info.id, info.title, podcast: info.podcastTitle)
            if let completion { completion() } else { self.onFinished?(info.id) }
        }
    }

    /// Si la descarga falla (sin red, error del servidor...), limpia el estado para no dejarla
    /// marcada como "descargando" para siempre.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        DispatchQueue.main.async { [weak self] in
            if let id = Self.decode(task.taskDescription)?.id { self?.downloading.remove(id) }
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
