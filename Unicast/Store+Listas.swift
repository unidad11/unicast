import Foundation

// MARK: - Listas

/// Listas de reproducción, manuales e inteligentes. En las inteligentes, el orden en que el usuario
/// colocó los podcasts decide dónde entra cada episodio nuevo.
@MainActor
extension AppStore {

    /// Añade episodios a una lista (selección múltiple → enviar a lista).
    func addEpisodes(_ episodeIDs: [UUID], to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for id in episodeIDs where !playlists[index].episodeIDs.contains(id) {
            playlists[index].episodeIDs.append(id)
        }
        save()
    }

    /// Crea una lista manual con los episodios indicados. Devuelve su id.
    @discardableResult
    func createPlaylist(name: String, episodeIDs: [UUID]) -> UUID {
        let playlist = Playlist(name: name.isEmpty ? "Nueva lista" : name, episodeIDs: episodeIDs)
        playlists.append(playlist)
        save()
        return playlist.id
    }

    /// Convierte una lista en inteligente: sus podcasts de origen pasan a ser las "fuentes",
    /// en el orden en que aparecen los episodios (esa es la prioridad por podcast).
    func makeSmart(_ playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var order: [UUID] = []
        for episodeID in playlists[index].episodeIDs {
            if let podcast = podcasts.first(where: { $0.episodes.contains { $0.id == episodeID } }),
               !order.contains(podcast.id) {
                order.append(podcast.id)
            }
        }
        playlists[index].isSmart = true
        playlists[index].sourcePodcastOrder = order
        save()
    }

    /// Cambia el nombre de una lista.
    func renamePlaylist(_ playlistID: UUID, name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        playlists[index].name = name
        save()
    }

    /// Quita un episodio de una lista (no borra el episodio de su podcast, solo sale de esta lista).
    func removeEpisodeFromPlaylist(_ episodeID: UUID, playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].episodeIDs.removeAll { $0 == episodeID }
        save()
    }

    /// Añade un podcast como fuente de una lista inteligente y mete ya sus descargados actuales
    /// (si no, habría que esperar a que publicara algo nuevo para ver el primer episodio).
    func addSourcePodcast(_ podcastID: UUID, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              let podcast = podcast(id: podcastID) else { return }
        if !playlists[index].sourcePodcastOrder.contains(podcastID) {
            playlists[index].sourcePodcastOrder.append(podcastID)
        }
        let already = Set(playlists[index].episodeIDs)
        let newIDs = podcast.downloadedEpisodes.map(\.id).filter { !already.contains($0) }
        playlists[index].episodeIDs.append(contentsOf: newIDs)
        save()
    }

    /// Mete los episodios nuevos en las listas inteligentes que siguen a ese podcast
    /// (la promesa de "los nuevos entran solos"; antes no estaba conectado al refresco).
    func addToSmartPlaylists(_ episodes: [Episode], from podcastID: UUID) {
        guard !episodes.isEmpty else { return }
        for index in playlists.indices
        where playlists[index].isSmart && playlists[index].sourcePodcastOrder.contains(podcastID) {
            playlists[index].episodeIDs.insert(contentsOf: episodes.map(\.id),
                                               at: insertionPoint(in: playlists[index], for: podcastID))
        }
    }

    /// Dónde colocar un episodio nuevo dentro de una lista inteligente.
    ///
    /// La promesa era que el orden en que el usuario colocó los podcasts (`sourcePodcastOrder`)
    /// decide la prioridad, y que un episodio nuevo entra en el sitio de SU podcast. En realidad
    /// ese orden solo se usaba para saber qué podcasts pertenecían a la lista, y todo lo nuevo se
    /// añadía al final: el campo podía haber sido un conjunto y nada habría cambiado.
    ///
    /// Aquí se busca el primer episodio de la lista cuyo podcast vaya DESPUÉS que este en el orden,
    /// y se coloca justo delante. Si no hay ninguno, va al final.
    private func insertionPoint(in playlist: Playlist, for podcastID: UUID) -> Int {
        guard let rank = playlist.sourcePodcastOrder.firstIndex(of: podcastID) else {
            return playlist.episodeIDs.count
        }
        for (position, episodeID) in playlist.episodeIDs.enumerated() {
            guard let owner = podcasts.first(where: { $0.episodes.contains { $0.id == episodeID } }),
                  let otherRank = playlist.sourcePodcastOrder.firstIndex(of: owner.id) else { continue }
            if otherRank > rank { return position }
        }
        return playlist.episodeIDs.count
    }

    /// Episodios de una lista, en su orden actual.
    func episodes(in playlist: Playlist) -> [Episode] {
        playlist.episodeIDs.compactMap { episode(id: $0) }
    }

    /// Reordena a mano los episodios de una lista (arrastrar).
    func movePlaylistItems(_ playlistID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].episodeIDs.move(fromOffsets: source, toOffset: destination)
        save()
    }
}
