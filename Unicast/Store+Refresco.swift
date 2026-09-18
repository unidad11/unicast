import Foundation

// MARK: - Refresco de feeds

/// Traer lo nuevo de los feeds y fusionarlo con lo que ya hay sin pisar el estado del usuario.
///
/// `merge` es el corazón de la app: decide qué episodio del feed es nuevo y cuál ya teníamos. Ahí
/// han vivido los peores fallos —episodios que desaparecían sin dar error— y por eso tiene una
/// batería de pruebas propia (`UnicastTests/FusionDeEpisodiosTests.swift`).
@MainActor
extension AppStore {

    // MARK: - Ajustes del refresco

    /// Como mucho estos feeds a la vez. Con 25 podcasts, lanzarlos TODOS de golpe satura la
    /// conexión del móvil y hace más fácil que alguno agote su tiempo sin haber empezado siquiera
    /// a transferir datos.
    static let maxConcurrentRefreshes = 5

    /// Como mucho un guardado cada tantos segundos durante el refresco. Antes era uno por CADA
    /// podcast cambiado: hasta 25 reescrituras completas del JSON de 10 MB en la misma ventana de
    /// ~30 segundos. El guardado final de después del bucle sigue garantizado pase lo que pase.
    static let saveThrottle: TimeInterval = 3

    /// Por dónde empezar el próximo refresco. Va en UserDefaults, no en el JSON de la biblioteca:
    /// es un dato de "por dónde voy", no de contenido.
    static let rotationKey = "unicast.refresh.rotationIndex"

    @discardableResult
    func refresh(downloads: DownloadManager) async -> RefreshSummary {
        guard beginRefresh() else {
            return RefreshSummary(changed: 0, failed: 0, total: 0, networkSeconds: 0, fastestDetectionSeconds: nil)
        }
        defer { endRefresh() }
        let all = podcasts
        guard !all.isEmpty else {
            return RefreshSummary(changed: 0, failed: 0, total: 0, networkSeconds: 0, fastestDetectionSeconds: nil)
        }
        let start = UserDefaults.standard.integer(forKey: Self.rotationKey) % all.count
        let current = Array(all[start...] + all[..<start])
        var changed = 0
        var failed = 0
        var processed = 0
        var networkSeconds: Double = 0
        var fastestDetectionSeconds: Double?
        var lastSaveAt = Date.distantPast
        await withTaskGroup(of: (UUID, FeedFetchResult, Double).self) { group in
            var queue = current.makeIterator()
            func launchNext() {
                while let podcast = queue.next() {
                    guard let feed = podcast.feedURL else { continue }
                    group.addTask { [colorHex = podcast.colorHex,
                                      etag = podcast.feedETag, lastModified = podcast.feedLastModified] in
                        let netStart = Date()
                        let result = await PodcastService.fetchIfChanged(feedURL: feed, colorHex: colorHex,
                                                                           etag: etag, lastModified: lastModified)
                        return (podcast.id, result, Date().timeIntervalSince(netStart))
                    }
                    return
                }
            }
            for _ in 0..<Self.maxConcurrentRefreshes { launchNext() }
            for await (id, result, netTime) in group {
                launchNext()   // uno termina: entra el siguiente de la cola, manteniendo el tope
                processed += 1
                networkSeconds += netTime
                // El punto de partida del siguiente refresco se guarda AQUÍ, según lo que de verdad
                // se ha terminado de procesar, y no al final del bucle. Dos motivos: si iOS corta
                // la tarea a mitad, la línea del final no llega a ejecutarse nunca; y la cuenta
                // anterior sumaba los podcasts LANZADOS, que al drenarse siempre el grupo entero
                // acababan siendo todos — `(start + total) % total` devuelve el mismo índice, así
                // que la rotación llevaba desde que se escribió sin rotar absolutamente nada.
                UserDefaults.standard.set((start + processed) % all.count, forKey: Self.rotationKey)
                if case .failed = result { failed += 1 }
                guard let index = podcasts.firstIndex(where: { $0.id == id }) else { continue }
                if case .fetched(let fresh, let etag, let lastModified) = result {
                    changed += 1
                    let newEpisodes = merge(fresh, into: index)
                    for episode in newEpisodes {
                        let detection = Date().timeIntervalSince(episode.publishedAt)
                        if fastestDetectionSeconds == nil || detection < fastestDetectionSeconds! {
                            fastestDetectionSeconds = detection
                        }
                    }
                    podcasts[index].feedETag = etag
                    podcasts[index].feedLastModified = lastModified
                }
                // Baja lo que falte y rota el límite SIEMPRE, traiga o no novedades el feed. Antes
                // esto vivía dentro del `case .fetched` y ahí estaba la fuga: con el refresco
                // condicional (ETag/304) la inmensa mayoría de los podcasts responden "sin
                // cambios", así que una descarga que había fallado no se reintentaba NUNCA — se
                // quedaba esperando a que ese podcast publicara un capítulo nuevo.
                applyAutoDownload(for: id, using: downloads)
                if Date().timeIntervalSince(lastSaveAt) >= Self.saveThrottle {
                    save()
                    lastSaveAt = Date()
                }
            }
        }
        lastRefreshAt = Date()
        save()
        return RefreshSummary(changed: changed, failed: failed, total: current.count,
                               networkSeconds: networkSeconds, fastestDetectionSeconds: fastestDetectionSeconds)
    }

    /// Vuelca lo nuevo de `fresh` sobre el podcast ya guardado, sin tocar el estado de lo que ya
    /// había, y repara URLs http:// antiguas en episodios ya existentes (carátula, audio y
    /// capítulos) — iOS las bloquea desde el arreglo del feed de Emilcar/Histocast, pero los
    /// episodios guardados antes de ese arreglo se quedaron con la URL vieja para siempre.
    /// Devuelve los episodios que eran realmente nuevos (para medir cuánto se tarda en detectarlos).
    /// Sin `private` únicamente para que las pruebas puedan llamarla: es el corazón de la app y
    /// donde han vivido los peores fallos. Fuera de `refresh` y de `UnicastTests` no la usa nadie.
    @discardableResult
    func merge(_ fresh: Podcast, into index: Int) -> [Episode] {
        var updated = podcasts[index]
        updated.summary = fresh.summary.isEmpty ? updated.summary : fresh.summary
        updated.artworkURL = fresh.artworkURL ?? updated.artworkURL

        // ---- Paso 1: emparejar identidades sueltas ----
        // Cubre dos casos que acaban igual: un episodio guardado que todavía no tiene identificador
        // (la biblioteca es de antes de que se leyera el <guid>), y uno cuyo identificador ya no
        // aparece en el feed porque el autor se lo ha cambiado — cosa que pasa de verdad, y que si
        // no se repara mete el mismo capítulo dos veces y lo vuelve a descargar entero.
        //
        // A cada uno se le busca el capítulo del feed con su MISMO título y la fecha MÁS CERCANA,
        // uno a uno y sin repetir. Lo de la fecha no es un detalle: hay programas que reciclan el
        // mismo título cada pocos meses. Le pasa a "Todo por la radio" de la SER, que el 15/09/2026
        // publicó un capítulo con el título exacto de otro del 07/07/2026. Emparejando solo por
        // título, el de septiembre le habría robado la identidad al de julio.
        let freshGuids = Set(fresh.episodes.compactMap(\.guid))
        var freshByTitle: [String: [Int]] = [:]
        for (position, episode) in fresh.episodes.enumerated() where episode.guid != nil {
            freshByTitle[episode.title, default: []].append(position)
        }
        // Los capítulos del feed cuyo identificador YA tenemos no están en juego: son de su dueño.
        let storedGuids = Set(updated.episodes.compactMap(\.guid))
        var claimed = Set<Int>()
        for (position, incoming) in fresh.episodes.enumerated() {
            if let guid = incoming.guid, storedGuids.contains(guid) { claimed.insert(position) }
        }
        for position in updated.episodes.indices {
            let stored = updated.episodes[position]
            // Tiene identificador y sigue en el feed: nada que hacer.
            if let guid = stored.guid, freshGuids.contains(guid) { continue }
            var best: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for candidate in freshByTitle[stored.title] ?? [] where !claimed.contains(candidate) {
                let distance = abs(fresh.episodes[candidate].publishedAt.timeIntervalSince(stored.publishedAt))
                if distance < bestDistance { bestDistance = distance; best = candidate }
            }
            // Si el episodio guardado YA tenía identificador, solo se le cambia cuando el del feed
            // es claramente el mismo capítulo (mismo título y prácticamente la misma fecha). Para
            // uno sin identificador se es más flexible: es el traspaso de la biblioteca vieja.
            guard let best else { continue }
            if stored.guid != nil && bestDistance > 2 * 86400 { continue }
            claimed.insert(best)
            updated.episodes[position].guid = fresh.episodes[best].guid
        }

        // ---- Paso 2: qué es nuevo de verdad ----
        var indexByGuid: [String: Int] = [:]
        var knownTitles = Set<String>()
        for (position, episode) in updated.episodes.enumerated() {
            if let guid = episode.guid, indexByGuid[guid] == nil { indexByGuid[guid] = position }
            knownTitles.insert(episode.title)
        }
        var newEpisodes: [Episode] = []
        var addedGuids = Set<String>()
        for incoming in fresh.episodes {
            if let guid = incoming.guid {
                // El identificador manda: si ya lo tenemos es el mismo capítulo, aunque le hayan
                // cambiado el título (antes eso lo hacía entrar otra vez y se re-descargaba entero).
                if let position = indexByGuid[guid] {
                    adopt(incoming, into: &updated.episodes[position])
                    continue
                }
                guard !addedGuids.contains(guid) else { continue }   // el feed lo repite: una vez
                addedGuids.insert(guid)
                // Nuevo aunque su título coincida con otro que ya teníamos: son dos capítulos
                // distintos con el mismo nombre, y el segundo se venía descartando en silencio.
                newEpisodes.append(incoming)
            } else {
                // Feed que no da identificadores: se compara por título, como siempre.
                if knownTitles.contains(incoming.title) { continue }
                knownTitles.insert(incoming.title)
                newEpisodes.append(incoming)
            }
        }

        updated.episodes = newEpisodes + updated.episodes   // los nuevos, primero
        for ei in updated.episodes.indices {
            updated.episodes[ei].artworkURL = updated.episodes[ei].artworkURL?.securedHTTPS
            updated.episodes[ei].audioURL = updated.episodes[ei].audioURL?.securedHTTPS
        }
        podcasts[index] = updated
        addToSmartPlaylists(newEpisodes, from: updated.id)
        return newEpisodes
    }

    /// Refresca de un episodio ya guardado lo que el feed puede cambiar sin que deje de ser el
    /// mismo episodio. NUNCA toca el estado del usuario: ni descargado, ni escuchado, ni la
    /// posición de reproducción.
    private func adopt(_ incoming: Episode, into stored: inout Episode) {
        if !incoming.title.isEmpty { stored.title = incoming.title }
        if stored.chaptersURL == nil { stored.chaptersURL = incoming.chaptersURL }
        if stored.audioBytes == nil { stored.audioBytes = incoming.audioBytes }
        if stored.audioURL == nil { stored.audioURL = incoming.audioURL }
    }

    /// Refresca solo si el último refresco tiene más de 5 minutos (al volver a la app).
    @discardableResult
    func refreshIfStale(downloads: DownloadManager) async -> RefreshSummary? {
        guard Date().timeIntervalSince(lastRefreshAt ?? .distantPast) > 5 * 60 else { return nil }
        return await refresh(downloads: downloads)
    }
}
