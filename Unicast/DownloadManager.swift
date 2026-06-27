import Foundation
import Observation

/// Descarga el audio de los episodios a disco (URLSession) para poder escucharlos sin conexión.
@Observable
final class DownloadManager {
    /// Episodios que se están descargando ahora mismo.
    var downloading: Set<UUID> = []

    /// Ruta local donde se guarda el audio de un episodio.
    static func localURL(for episodeID: UUID) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(episodeID).mp3")
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

    /// Descarga el audio del episodio. Llama a `completion` en el hilo principal al terminar.
    func download(_ episode: Episode, completion: @escaping () -> Void) {
        guard let url = episode.audioURL, !downloading.contains(episode.id) else { return }
        downloading.insert(episode.id)
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, _ in
            if let tempURL {
                let destination = DownloadManager.localURL(for: episode.id)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: tempURL, to: destination)
            }
            DispatchQueue.main.async {
                self?.downloading.remove(episode.id)
                Notifications.notifyDownloaded(episode.title, podcast: episode.podcastTitle)
                completion()
            }
        }.resume()
    }

    /// Borra el audio descargado de un episodio (al escucharlo y autoborrarlo, etc.).
    static func deleteFile(for episodeID: UUID) {
        try? FileManager.default.removeItem(at: localURL(for: episodeID))
    }
}
