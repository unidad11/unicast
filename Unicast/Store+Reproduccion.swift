import Foundation

// MARK: - Reproducción

/// Lo que rodea al reproductor: qué suena, dónde se quedó cada episodio, qué pasa al terminar uno y
/// cuál va después.
@MainActor
extension AppStore {

    /// Arranca un episodio en el reproductor.
    func play(_ episode: Episode) {
        nowPlaying = episode
        isPlaying = true
    }

    /// Rellena la carátula del episodio con la del podcast (para el Now Playing / isla).
    func enrich(_ episode: Episode) -> Episode {
        guard episode.artworkURL == nil,
              let podcast = podcasts.first(where: { $0.title == episode.podcastTitle }) else { return episode }
        var copy = episode
        copy.artworkURL = podcast.artworkURL
        return copy
    }

    /// Guarda la posición exacta de un episodio (para retomarlo donde se dejó).
    func updatePlaybackPosition(_ episodeID: UUID, _ time: TimeInterval) {
        for pi in podcasts.indices {
            if let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) {
                podcasts[pi].episodes[ei].playbackPosition = time
                return
            }
        }
    }

    /// Guarda los capítulos descargados del JSON aparte, para no volver a pedirlos cada vez.
    func setChapters(_ chapters: [Chapter], for episodeID: UUID) {
        for pi in podcasts.indices {
            if let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) {
                podcasts[pi].episodes[ei].chapters = chapters
                save()
                return
            }
        }
    }

    /// Al terminar un episodio: autoborrado (quita el audio y lo saca de Descargados → vuelve a Todos).
    func handleFinished(_ episodeID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.episodes.contains { $0.id == episodeID } }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        // "Borrar al terminar" es un ajuste POR PODCAST que estaba en la pantalla de ajustes desde
        // el principio y no lo consultaba nadie: el audio se borraba siempre, lo tuvieras puesto o
        // no. Si está apagado, el episodio se marca escuchado pero el archivo se queda.
        if podcasts[pi].autoDeleteOnFinish {
            DownloadManager.deleteFile(for: episodeID)
            podcasts[pi].episodes[ei].isDownloaded = false
            podcasts[pi].episodes[ei].manuallyDownloaded = false
        }
        podcasts[pi].episodes[ei].isPlayed = true   // escuchado: sale atenuado y no se re-descarga
        podcasts[pi].episodes[ei].playbackPosition = 0
        save()
    }

    /// Siguiente episodio a reproducir en cadena, según el sentido continuo del podcast (punto 5).
    func nextEpisode(after episodeID: UUID) -> Episode? {
        guard let podcast = podcasts.first(where: { $0.episodes.contains { $0.id == episodeID } }) else { return nil }
        // La reproducción continua va SOLO entre los descargados.
        let pool = podcast.downloadedEpisodes
        let ordered = podcast.continuousDirection == .posteriores
            ? pool.sorted { $0.publishedAt < $1.publishedAt }
            : pool.sorted { $0.publishedAt > $1.publishedAt }
        guard let index = ordered.firstIndex(where: { $0.id == episodeID }),
              index + 1 < ordered.count else { return nil }
        return ordered[index + 1]
    }

    /// Devuelve un episodio a "no escuchado", para que la auto-descarga vuelva a ocuparse de él.
    ///
    /// Hasta ahora `isPlayed` era un camino de ida sin vuelta: lo ponen a true tanto terminar un
    /// episodio como descartarlo deslizando, y NADA en toda la app lo devolvía a false. Un capítulo
    /// descartado por error quedaba excluido de la descarga automática para siempre, sin ninguna
    /// forma de deshacerlo.
    func markUnplayed(_ episodeID: UUID, in podcastID: UUID) {
        guard let pi = podcasts.firstIndex(where: { $0.id == podcastID }),
              let ei = podcasts[pi].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        podcasts[pi].episodes[ei].isPlayed = false
        podcasts[pi].episodes[ei].downloadFailures = 0   // que se reintente ya, sin esperas
        podcasts[pi].episodes[ei].lastDownloadFailureAt = nil
        save()
    }
}
