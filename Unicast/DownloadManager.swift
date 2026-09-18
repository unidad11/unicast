import Foundation
import Observation
import UIKit

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

    /// Aviso de "esta descarga ha fallado". Hace falta para no reintentar eternamente una URL
    /// muerta: quien escucha apunta el fallo en el episodio y aplica una espera creciente.
    @ObservationIgnored
    var onFailed: ((UUID) -> Void)?

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
        /// ¿Avisar al terminar? Es el ajuste "Avisarme de nuevos" del podcast, que hasta ahora no
        /// lo miraba nadie: se notificaba SIEMPRE. Viaja dentro de la tarea para que la decisión
        /// sobreviva a que la app se cierre antes de que termine la descarga. Opcional a
        /// propósito: las tareas ya en vuelo de la versión anterior no lo traen.
        var notify: Bool?
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
        // OJO: esto NO hace que las descargas en segundo plano empiecen antes. Apple lo dice sin
        // ambigüedad: "For transfers started while your app is in the background, the system
        // always starts transfers at its discretion (...) and ignores any value you specified."
        // Solo tiene efecto en las descargas que arrancan con la app ABIERTA (botón de descargar
        // a mano), que es donde de verdad sirve de algo dejarlo en false.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Por defecto iOS da 7 DÍAS para completar una transferencia en segundo plano: una
        // descarga atascada (servidor caído, feed que dejó de existir) se queda "descargando"
        // toda una semana en vez de fallar pronto. Con esto falla en 48h, `downloading` se limpia
        // en `didCompleteWithError`, y el episodio se reintenta solo en el siguiente refresco.
        config.timeoutIntervalForResource = 48 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// Fuerza la creación de la sesión en segundo plano (al arrancar o al despertar la app), para
    /// que iOS pueda reengancharnos a descargas que ya estaban en marcha, y repuebla la lista de
    /// "descargando ahora" preguntándole al sistema qué sigue en vuelo. Sin esto, al reabrir la app
    /// las descargas en curso no mostraban la ruedecita y se podían encolar dos veces.
    /// `completion` se llama SIEMPRE, en el hilo principal, cuando `downloading` ya refleja lo que
    /// iOS tiene en vuelo. Importa el orden: el repaso de descargas se hacía justo después de
    /// llamar aquí, pero `getAllTasks` responde de forma asíncrona, así que el repaso corría con la
    /// lista todavía vacía y podía encolar por segunda vez un mp3 que ya se estaba bajando.
    func attachBackgroundSession(completion: (() -> Void)? = nil) {
        session.getAllTasks { tasks in
            let ids = tasks.compactMap { Self.decode($0.taskDescription)?.id }
            DispatchQueue.main.async { [weak self] in
                for id in ids { self?.downloading.insert(id) }
                completion?()
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

    /// Dónde se guardan los datos de reanudación de las descargas que se cortaron a medias.
    ///
    /// Una descarga nocturna se corta con facilidad: el móvil cambia de red, se suspende un
    /// instante, el servidor cierra la conexión. Sin esto se volvía a empezar desde cero cada vez
    /// —y un episodio de 150 MB no terminaba nunca si se cortaba a la mitad de forma habitual—.
    /// Con el "recibo" que da iOS al cancelar, la descarga sigue por donde iba. Lo hacen tanto
    /// Pocket Casts como AntennaPod, cada uno a su manera.
    private static var resumeDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("resume", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func resumeURL(for episodeID: UUID) -> URL {
        resumeDirectory.appendingPathComponent("\(episodeID).resume")
    }

    private static func saveResumeData(_ data: Data, for episodeID: UUID) {
        try? data.write(to: resumeURL(for: episodeID), options: .atomic)
    }

    private static func takeResumeData(for episodeID: UUID) -> Data? {
        let url = resumeURL(for: episodeID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    private static func discardResumeData(for episodeID: UUID) {
        try? FileManager.default.removeItem(at: resumeURL(for: episodeID))
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
    ///
    /// `allowsCellular` es donde se aplica de verdad el ajuste "Descargar solo con WiFi": las
    /// descargas AUTOMÁTICAS (refresco nocturno, rotación del límite) lo pasan a false cuando el
    /// ajuste está puesto, y entonces iOS deja la transferencia esperando a que haya WiFi en vez
    /// de gastar datos del móvil. Las que pide el usuario a mano NUNCA lo aplican: si pulsa el
    /// botón de descargar es porque quiere ese episodio ahora, con la red que haya.
    func download(_ episode: Episode, allowsCellular: Bool = true, notify: Bool = true,
                   completion: @escaping () -> Void) {
        guard let url = episode.audioURL, !downloading.contains(episode.id) else { return }
        downloading.insert(episode.id)
        // Si esta descarga se quedó a medias, se retoma donde iba en vez de empezar de cero.
        let task: URLSessionDownloadTask
        let resumed: Bool
        if let resumeData = Self.takeResumeData(for: episode.id) {
            task = session.downloadTask(withResumeData: resumeData)
            resumed = true
        } else {
            var request = URLRequest(url: url)
            request.allowsCellularAccess = allowsCellular
            task = session.downloadTask(with: request)
            resumed = false
        }
        // Cuánto va a pesar esto. Apple lo pide expresamente en el SDK ("the system uses this to
        // optimize the scheduling of URL session tasks (...) developers are strongly encouraged to
        // provide an approximate upper bound"), y es la ÚNICA influencia que tiene la app sobre
        // cuándo decide iOS arrancar una transferencia en segundo plano — que es exactamente lo
        // que hace que un episodio detectado a la 1:00 no esté en el móvil hasta las 7:00. Sin
        // esto, para el planificador son descargas de tamaño desconocido.
        if let bytes = episode.audioBytes { task.countOfBytesClientExpectsToReceive = bytes }
        // La identidad del episodio viaja DENTRO de la tarea, no solo en memoria: es lo que hace
        // que una descarga terminada de madrugada se pueda guardar en su sitio al despertar.
        task.taskDescription = Self.encode(TaskInfo(id: episode.id,
                                                    title: episode.title,
                                                    podcastTitle: episode.podcastTitle,
                                                    notify: notify))
        pending[task.taskIdentifier] = completion
        // Se apunta la hora de ENCOLADO y si la app estaba en primer plano, que es lo que decide
        // si iOS arranca la transferencia ya o la aparca a su gusto.
        let foreground = Self.isForeground()
        DownloadLog.queued(DownloadEvent(episodeID: episode.id,
                                          title: resumed ? "\(episode.title) (retomada)" : episode.title,
                                          podcastTitle: episode.podcastTitle, queuedAt: Date(),
                                          foreground: foreground, expectedBytes: episode.audioBytes))
        task.resume()
    }

    /// ¿Está la app en primer plano ahora mismo? Se consulta sin bloquear: si la llamada llega
    /// desde fuera del hilo principal (un refresco en segundo plano), se da por segundo plano, que
    /// es además lo correcto en ese caso.
    private static func isForeground() -> Bool {
        guard Thread.isMainThread else { return false }
        return UIApplication.shared.applicationState == .active
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
        guard let info = Self.decode(downloadTask.taskDescription) else {
            // Sin ficha no se sabe de qué episodio era, pero hay que soltar la entrada de `pending`
            // igualmente: era el único final que la dejaba colgada para siempre.
            DispatchQueue.main.async { [weak self] in self?.pending[downloadTask.taskIdentifier] = nil }
            return
        }
        // Un 404 o un "servidor caído" también llega hasta aquí, con la página de error como
        // contenido. Sin esta comprobación se guardaba como si fuera el episodio y quedaba
        // marcado "Descargado" un archivo de 77 bytes que no suena.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        // Un servidor puede responder 200 con una página de error en HTML en lugar del audio. Si
        // dice que es texto y además pesa poco, no es un episodio: es un aviso de error. Pocket
        // Casts y AntennaPod hacen esta misma comprobación, cada uno por su cuenta.
        let tipo = (downloadTask.response?.mimeType ?? "").lowercased()
        let pareceTexto = tipo.contains("text") || tipo.contains("html") || tipo.contains("xml")
        guard (200...299).contains(status), size >= Self.minimumValidSize,
              !(pareceTexto && size < 150 * 1024) else {
            Self.discardResumeData(for: info.id)
            let motivo = pareceTexto ? "el servidor devolvió texto, no audio" : "HTTP \(status), \(size) bytes"
            DownloadLog.finished(info.id, outcome: "descartada (\(motivo))", bytes: size)
            DispatchQueue.main.async { [weak self] in
                self?.downloading.remove(info.id)
                self?.pending[downloadTask.taskIdentifier] = nil
                self?.onFailed?(info.id)
            }
            return
        }
        Self.discardResumeData(for: info.id)   // terminó bien: el recibo ya no vale
        let destination = DownloadManager.localURL(for: info.id)
        try? FileManager.default.removeItem(at: destination)
        let success = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        DownloadLog.finished(info.id, outcome: success ? "guardada" : "fallo al guardar", bytes: size)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downloading.remove(info.id)
            let completion = self.pending.removeValue(forKey: downloadTask.taskIdentifier)
            guard success else { return }
            if info.notify ?? true {
                Notifications.notifyDownloaded(info.id, info.title, podcast: info.podcastTitle)
            }
            if let completion { completion() } else { self.onFinished?(info.id) }
        }
    }

    /// Si la descarga falla (sin red, error del servidor...), limpia el estado para no dejarla
    /// marcada como "descargando" para siempre.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if let id = Self.decode(task.taskDescription)?.id {
            // iOS entrega un "recibo" con lo que ya se había bajado: se guarda para retomar la
            // descarga por donde iba en vez de volver a empezar.
            if let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                Self.saveResumeData(resumeData, for: id)
                DownloadLog.finished(id, outcome: "cortada, se retomará donde iba", bytes: nil)
            } else {
                DownloadLog.finished(id, outcome: "error: \(ns.localizedDescription)", bytes: nil)
            }
        }
        DispatchQueue.main.async { [weak self] in
            if let id = Self.decode(task.taskDescription)?.id {
                self?.downloading.remove(id)
                self?.onFailed?(id)
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
