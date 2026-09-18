import Foundation

/// Lo que Unicast guarda en disco entre sesiones.
struct AppState: Codable {
    var podcasts: [Podcast]
    var playlists: [Playlist]
    var backgroundStyle: BackgroundStyle
    var showNewCountBadges: Bool
    var libraryLayout: LibraryLayout
    var wifiOnlyDownloads: Bool
    var defaultDownloadLimit: DownloadLimit
    var nowPlayingID: UUID?

    init(podcasts: [Podcast], playlists: [Playlist], backgroundStyle: BackgroundStyle,
         showNewCountBadges: Bool, libraryLayout: LibraryLayout, wifiOnlyDownloads: Bool,
         defaultDownloadLimit: DownloadLimit, nowPlayingID: UUID?) {
        self.podcasts = podcasts
        self.playlists = playlists
        self.backgroundStyle = backgroundStyle
        self.showNewCountBadges = showNewCountBadges
        self.libraryLayout = libraryLayout
        self.wifiOnlyDownloads = wifiOnlyDownloads
        self.defaultDownloadLimit = defaultDownloadLimit
        self.nowPlayingID = nowPlayingID
    }

    private enum CodingKeys: String, CodingKey {
        case podcasts, playlists, backgroundStyle, showNewCountBadges
        case libraryLayout, wifiOnlyDownloads, defaultDownloadLimit, nowPlayingID
    }

    /// Carga tolerante: un ajuste nuevo, uno renombrado o un podcast corrupto ya NO tiran abajo
    /// la biblioteca entera. Antes cualquier fallo dejaba `Persistence.load()` en nil, entraban
    /// los podcasts de ejemplo y la limpieza de huérfanos se llevaba por delante TODO el audio
    /// descargado. Lo que no se entienda se sustituye por su valor por defecto y punto.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        podcasts = c.lenientArray(Podcast.self, .podcasts)
        playlists = c.lenientArray(Playlist.self, .playlists)
        backgroundStyle = c.lenient(.backgroundStyle, or: BackgroundStyle.blueNight)
        showNewCountBadges = c.lenient(.showNewCountBadges, or: false)
        libraryLayout = c.lenient(.libraryLayout, or: LibraryLayout.grid)
        wifiOnlyDownloads = c.lenient(.wifiOnlyDownloads, or: true)
        defaultDownloadLimit = c.lenient(.defaultDownloadLimit, or: DownloadLimit.last(5))
        nowPlayingID = c.lenientOptional(UUID.self, .nowPlayingID)
    }
}

/// Guarda y carga el estado en Application Support/unicast_state.json.
enum Persistence {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var fileURL: URL { directory.appendingPathComponent("unicast_state.json") }

    /// Cola propia para escribir. La biblioteca del usuario son 10 MB de JSON: codificarla y
    /// escribirla cuesta cientos de milisegundos, y ahora que el store vive en el hilo principal
    /// hacerlo ahí sería un tirón visible cada pocos segundos durante un refresco — y tiempo
    /// tirado de la ventana de segundo plano, que es justo lo que no sobra.
    ///
    /// Es una cola SERIE: los guardados se aplican en el mismo orden en que se piden, así que
    /// ninguno puede adelantar a otro y dejar en disco un estado viejo.
    private static let ioQueue = DispatchQueue(label: "com.jbs.Unicast.persistence", qos: .utility)

    /// Último estado pendiente de escribir. Si llegan treinta guardados seguidos (y llegan: uno
    /// por cada descarga terminada y uno por cada episodio que rota fuera del límite), solo importa
    /// el último: todos escriben el MISMO archivo. Sin esto se codificaban y escribían los 10 MB
    /// treinta veces para dejar exactamente el mismo resultado.
    private static var pendingState: AppState?
    private static let pendingLock = NSLock()

    /// El estado que se pasa es una copia por valor, así que se puede escribir tranquilamente
    /// mientras el store sigue cambiando.
    static func save(_ state: AppState) {
        pendingLock.lock()
        let alreadyScheduled = pendingState != nil
        pendingState = state
        pendingLock.unlock()
        guard !alreadyScheduled else { return }   // ya hay una escritura en camino; se llevará este
        ioQueue.async { writePending() }
    }

    /// Escribe lo último que haya pendiente, sea de quien sea.
    private static func writePending() {
        pendingLock.lock()
        let state = pendingState
        pendingState = nil
        pendingLock.unlock()
        guard let state, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Espera a que termine todo lo que haya pendiente de escribir. Hay que llamarlo al mandar la
    /// app a segundo plano: si iOS suspende el proceso con un guardado a medio salir de la cola,
    /// ese guardado se pierde.
    static func flush() {
        ioQueue.sync { }
        // Puede haber entrado un estado nuevo mientras se escribía el anterior: ese todavía no
        // tiene escritura en camino, así que hay que forzarla y esperarla también.
        pendingLock.lock()
        let stillPending = pendingState != nil
        pendingLock.unlock()
        if stillPending { ioQueue.sync { writePending() } }
    }

    /// Qué pasó al intentar cargar. Son tres casos MUY distintos y antes se devolvía `nil` para
    /// los tres, que es lo que hacía que un fallo pasajero de lectura acabara con la biblioteca de
    /// ejemplo escrita ENCIMA de los 25 podcasts del usuario.
    enum LoadResult {
        /// Se cargó bien.
        case loaded(AppState)
        /// No hay archivo: instalación nueva. Aquí sí vale empezar con datos de ejemplo.
        case fresh
        /// HAY archivo pero no se pudo leer. Nunca, jamás, escribir encima.
        case unreadable
    }

    /// Un JSON ilegible se APARTA con la fecha en el nombre (por si algún día hay forma de
    /// rescatarlo). Un error de LECTURA, en cambio, no se toca: el archivo puede estar
    /// perfectamente bien y ser el sistema el que no deja leerlo todavía — pasa de verdad cuando
    /// iOS lanza la app en segundo plano tras un reinicio, antes del primer desbloqueo, con la
    /// protección de datos aún cerrada. Ahí lo correcto es no hacer nada y reintentar luego.
    static func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .fresh }
        guard let data = try? Data(contentsOf: fileURL) else { return .unreadable }
        if let state = try? JSONDecoder().decode(AppState.self, from: data) { return .loaded(state) }
        quarantineCorruptFile()
        return .fresh   // el original está a salvo apartado; ya se puede empezar de cero
    }

    /// Mueve el archivo ilegible a un lado (unicast_state_corrupto_<fecha>.json).
    private static func quarantineCorruptFile() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = directory.appendingPathComponent("unicast_state_corrupto_\(stamp).json")
        try? FileManager.default.moveItem(at: fileURL, to: destination)
    }
}

// MARK: - Decodificación tolerante

/// Marcador que acepta cualquier JSON sin mirarlo. Sirve para SALTARSE un elemento roto de una
/// lista: hay que consumirlo igualmente o el bucle de `lenientArray` se quedaría dando vueltas
/// sobre el mismo sitio.
private struct AnyDecodedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

extension KeyedDecodingContainer {
    /// Lee un campo obligatorio. Si falta, viene nulo o está corrupto, devuelve `fallback` en vez
    /// de lanzar el error que haría fracasar la carga entera.
    func lenient<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    /// Igual, para los campos que ya son opcionales de por sí.
    func lenientOptional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Lee una lista descartando SOLO los elementos rotos, en vez de perder la lista entera por
    /// culpa de uno malo (un episodio ilegible no debe costar los otros 300 del podcast).
    func lenientArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !list.isAtEnd {
            let index = list.currentIndex
            if let item = try? list.decode(T.self) { result.append(item); continue }
            if (try? list.decodeNil()) == true { continue }
            _ = try? list.decode(AnyDecodedValue.self)
            // Red de seguridad: si nada ha consumido el elemento, parar antes que girar en bucle.
            guard list.currentIndex > index else { break }
        }
        return result
    }
}
