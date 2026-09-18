import Foundation

// MARK: - Descargas

/// Todo lo que decide QUÉ audio está en el móvil: qué se baja solo, qué se borra al rotar, qué se
/// recupera cuando falta, y qué hacer cuando una descarga falla.
///
/// Es la parte de la app donde más fallos han vivido, así que es también la que más pruebas tiene
/// (ver `UnicastTests/VentanaDeDescargaTests.swift`).
@MainActor
extension AppStore {

    /// Borra un episodio de un podcast (deslizar para borrar).
    func removeEpisode(_ episodeID: UUID, from podcastID: UUID) {
        discard([episodeID], in: podcastID)
    }

    /// Borra varios episodios a la vez (selección múltiple).
    func removeEpisodes(_ episodeIDs: Set<UUID>, from podcastID: UUID) {
        discard(Array(episodeIDs), in: podcastID)
    }

    /// Descarta episodios: borra el audio y los marca escuchados SIN sacarlos del registro.
    /// Clave anti-bug: si se eliminaran del todo, el siguiente refresco los traería como
    /// "nuevos" y el auto-descargar los volvería a bajar (los 4 que resucitaban).
    private func discard(_ episodeIDs: [UUID], in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        let ids = Set(episodeIDs)
        for ei in podcasts[pi].episodes.indices where ids.contains(podcasts[pi].episodes[ei].id) {
            DownloadManager.deleteFile(for: podcasts[pi].episodes[ei].id)
            podcasts[pi].episodes[ei].isDownloaded = false
            // Sigue visible en "Todos", atenuado; lo que se evita es que la auto-descarga lo
            // vuelva a bajar. Si fue un descarte por error, se deshace deslizando → "Pendiente".
            podcasts[pi].episodes[ei].isPlayed = true
            podcasts[pi].episodes[ei].playbackPosition = 0
            podcasts[pi].episodes[ei].manuallyDownloaded = false
        }
        save()
    }

    /// Marca un episodio como descargado buscando por su cuenta a qué podcast pertenece. Se usa
    /// cuando la descarga termina con la app cerrada: ahí no hay ninguna pantalla abierta que sepa
    /// de qué podcast venía.
    func markDownloaded(_ episodeID: UUID) {
        guard let podcast = podcasts.first(where: { $0.episodes.contains { $0.id == episodeID } }) else { return }
        markDownloaded(episodeID, in: podcast.id)
    }

    /// Marca un episodio como descargado.
    func markDownloaded(_ episodeID: UUID, in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].isDownloaded = true
        podcasts[pi].episodes[ei].downloadFailures = 0   // salió bien: se olvida lo anterior
        podcasts[pi].episodes[ei].lastDownloadFailureAt = nil
        save()
    }

    /// Apunta que una descarga ha fallado, para no reintentarla sin parar.
    func markDownloadFailed(_ episodeID: UUID) {
        for pi in podcasts.indices {
            if let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) {
                podcasts[pi].episodes[ei].downloadFailures += 1
                podcasts[pi].episodes[ei].lastDownloadFailureAt = Date()
                save()
                return
            }
        }
    }

    /// ¿Toca esperar antes de volver a intentar este episodio? La espera se dobla con cada fallo
    /// (1 h, 2 h, 4 h...) y se queda en 24 h como mucho. Así una URL muerta se intenta una vez al
    /// día en vez de quince, pero si el servidor vuelve, el episodio se recupera solo.
    private func waitingAfterFailure(_ episode: Episode) -> Bool {
        guard episode.downloadFailures > 0, let last = episode.lastDownloadFailureAt else { return false }
        let hours = min(pow(2.0, Double(episode.downloadFailures - 1)), 24)
        return Date().timeIntervalSince(last) < hours * 3600
    }

    /// Apunta que esta descarga la ha pedido el usuario a mano (botón de descargar en "Todos").
    /// Se marca AL PULSAR, no al terminar: si la descarga acaba de madrugada con la app cerrada,
    /// la marca ya está guardada y la rotación del límite no se lo lleva por delante.
    func markManuallyDownloaded(_ episodeID: UUID, in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].manuallyDownloaded = true
        save()
    }

    /// Pone al día la marca "Descargado" con lo que hay de verdad en disco, y vuelve a bajar lo
    /// que falte y estuviera a medio escuchar. Devuelve cuántos episodios se habían quedado sin audio.
    ///
    /// Hace falta porque el audio vivía en Caches, una carpeta que iOS vacía por su cuenta cuando
    /// le falta espacio (empezando por los archivos grandes, o sea los episodios largos). El
    /// episodio decía "Descargado" sin tener mp3, y el reproductor tiraba de streaming en silencio.
    /// NO se toca `playbackPosition`: el episodio se retoma donde se dejó.
    ///
    /// También al revés: si el mp3 está en disco pero el episodio no figura como descargado, se
    /// marca. Es la red de seguridad para las descargas que iOS termina con la app cerrada, donde
    /// no hay nadie escuchando para apuntarlo.
    @discardableResult
    func reconcileDownloads(using downloads: DownloadManager) -> Int {
        // Con la biblioteca de ejemplo cargada no hay nada real que repasar: lo único que se
        // conseguiría es ponerse a bajar los episodios de mentira de `SampleData`.
        guard !isSampleLibrary else { return 0 }
        var missing: [(episode: Episode, podcastID: UUID)] = []
        var recovered = 0
        for pi in podcasts.indices {
            for ei in podcasts[pi].episodes.indices {
                let onDisk = DownloadManager.isDownloaded(podcasts[pi].episodes[ei].id)
                switch (podcasts[pi].episodes[ei].isDownloaded, onDisk) {
                case (true, false):     // decía "Descargado" pero el audio ya no está
                    podcasts[pi].episodes[ei].isDownloaded = false
                    missing.append((podcasts[pi].episodes[ei], podcasts[pi].id))
                case (false, true):     // el audio está pero nadie lo marcó: descarga terminada
                    podcasts[pi].episodes[ei].isDownloaded = true   // con la app cerrada
                    recovered += 1
                default:
                    break
                }
            }
        }
        guard !missing.isEmpty || recovered > 0 else { return 0 }
        save()
        // Se rebajan TODOS los que se quedaron sin audio, no solo los empezados. Antes solo se
        // recuperaban los de `playbackPosition > 0` y el resto quedaba a la espera del refresco —
        // que nunca los recogía si ya habían salido de la ventana de auto-descarga: eran capítulos
        // marcados "Descargado" que en el móvil no existían y nadie volvía a bajar jamás.
        for item in missing where !item.episode.isPlayed {
            // Uno que el usuario bajó a mano se recupera con la red que haya; los automáticos
            // respetan "Descargar solo con WiFi".
            let cellular = item.episode.manuallyDownloaded || !wifiOnlyDownloads
            downloads.download(item.episode, allowsCellular: cellular) { [weak self] in
                self?.markDownloaded(item.episode.id, in: item.podcastID)
            }
        }
        return missing.count
    }

    /// Sigue un podcast (lo añade a la biblioteca) si no estaba ya.
    func subscribe(_ podcast: Podcast, downloads: DownloadManager) {
        guard !podcasts.contains(where: { $0.title == podcast.title }) else { return }
        var fresh = podcast
        // El límite elegido en Ajustes → "Guardar por defecto". Estaba ahí desde el principio y no
        // se aplicaba en ningún sitio: todo podcast nuevo se quedaba con los 5 de fábrica.
        fresh.downloadLimit = defaultDownloadLimit
        // Fecha de alta = corte. Se bajan los 4 más recientes (base) y, de ahí en adelante,
        // lo que se publique. NUNCA el histórico anterior a esa fecha.
        let byNewest = fresh.episodes.sorted { $0.publishedAt > $1.publishedAt }
        let base = 4
        fresh.downloadFromDate = byNewest.count >= base ? byNewest[base - 1].publishedAt
                                                        : (byNewest.last?.publishedAt ?? Date())
        podcasts.append(fresh)
        save()
        applyAutoDownload(for: fresh.id, using: downloads)
    }

    /// Mantiene descargados los últimos N episodios (según el límite del podcast) y borra los
    /// descargados más antiguos que sobren (rotación). N = todos si el límite es .all.
    func applyAutoDownload(for podcastID: UUID, using downloads: DownloadManager) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }), podcasts[pi].autoDownload else { return }
        // Migración: si un podcast viejo no tiene fecha de alta, la fijo al 4º más reciente
        // (así no vuelve a bajar el histórico).
        if podcasts[pi].downloadFromDate == nil {
            podcasts[pi].downloadFromDate = effectiveDownloadFrom(podcasts[pi])
        }
        let podcast = podcasts[pi]
        let keep = autoDownloadWindow(for: podcast)
        let keepIDs = Set(keep.map(\.id))
        // También se pregunta al disco, no solo al flag en memoria: si `onFinished` no llegó a
        // marcar una descarga de la noche (el caso que arregla el bug de arriba, en versiones
        // futuras si volviera a colarse uno parecido), sin este chequeo se re-descargaría el
        // mismo mp3 entero en cada refresco, varias veces al día.
        for ep in keep
        where !ep.isDownloaded && !ep.isPlayed && !DownloadManager.isDownloaded(ep.id) && !waitingAfterFailure(ep) {
            downloads.download(ep, allowsCellular: !wifiOnlyDownloads, notify: podcast.notifyNew) { [weak self] in
                self?.markDownloaded(ep.id, in: podcastID)
            }
        }
        // Rotación: borrar los descargados que ya no entran (sin empezar a escuchar). Los que el
        // usuario se bajó A MANO quedan fuera de la rotación: los eligió él, los borra él.
        for ep in podcast.episodes
        where ep.isDownloaded && !keepIDs.contains(ep.id) && ep.playbackPosition == 0 && !ep.manuallyDownloaded {
            removeFromDownloads(ep.id, in: podcastID)
        }
    }

    /// Qué episodios DEBERÍAN estar descargados de un podcast: los publicados desde el alta
    /// (nunca el histórico anterior), los más recientes primero, recortados al límite del podcast.
    func autoDownloadWindow(for podcast: Podcast) -> [Episode] {
        let from = effectiveDownloadFrom(podcast)
        let eligible = podcast.episodes.filter { $0.publishedAt >= from }.sorted { $0.publishedAt > $1.publishedAt }
        switch podcast.downloadLimit {
        case .all: return eligible
        case .last(let n): return Array(eligible.prefix(n))
        }
    }

    /// Fecha de corte efectiva de un podcast. Si es de antes de que existiera `downloadFromDate`,
    /// se comporta como si fuera la del 4º episodio más reciente — el mismo criterio que usa la
    /// migración de `applyAutoDownload`, para que consultar y actuar den siempre lo mismo.
    func effectiveDownloadFrom(_ podcast: Podcast) -> Date {
        if let date = podcast.downloadFromDate { return date }
        let sorted = podcast.episodes.sorted { $0.publishedAt > $1.publishedAt }
        if sorted.count >= 4 { return sorted[3].publishedAt }
        // Sin episodios el corte NO puede ser "ahora": si el podcast acaba de estrenarse y su
        // primer capítulo trae una fecha anterior al momento exacto en que le diste a seguir
        // —cosa normal—, ese capítulo quedaría fuera para siempre. Sin histórico que proteger,
        // el pasado es seguro: el límite de descargas ya acota cuántos se bajan.
        return sorted.last?.publishedAt ?? .distantPast
    }

    /// Todo lo que debería estar descargado en la biblioteca y todavía no está. Es la lista que
    /// enseña la pantalla de diagnóstico, y lo que baja su botón.
    func pendingDownloads() -> [PendingDownload] {
        var pending: [PendingDownload] = []
        for podcast in podcasts where podcast.autoDownload {
            for ep in autoDownloadWindow(for: podcast)
            where !ep.isPlayed && !DownloadManager.isDownloaded(ep.id) {
                pending.append(PendingDownload(episode: ep, podcastID: podcast.id))
            }
        }
        return pending
    }

    /// Baja ya todo lo que falte (botón "Descargar lo que falta" del diagnóstico). Lo pide el
    /// usuario, así que NO se aplica "Descargar solo con WiFi".
    func downloadPending(using downloads: DownloadManager) {
        for item in pendingDownloads() {
            downloads.download(item.episode) { [weak self] in
                self?.markDownloaded(item.episode.id, in: item.podcastID)
            }
        }
    }

    /// Quita un episodio de Descargados (borra el audio) sin marcarlo escuchado — para la rotación.
    func removeFromDownloads(_ episodeID: UUID, in podcastID: UUID) {
        DownloadManager.deleteFile(for: episodeID)
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].isDownloaded = false
        podcasts[pi].episodes[ei].manuallyDownloaded = false
        save()
    }

    /// Borra TODAS las descargas de un podcast (el audio), dejando los episodios en "Todos".
    func clearDownloads(for podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }) else { return }
        for ep in podcasts[pi].episodes where ep.isDownloaded { DownloadManager.deleteFile(for: ep.id) }
        for ei in podcasts[pi].episodes.indices {
            podcasts[pi].episodes[ei].isDownloaded = false
            podcasts[pi].episodes[ei].manuallyDownloaded = false
        }
        save()
    }
}
