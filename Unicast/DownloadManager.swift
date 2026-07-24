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

    /// Descarga el audio del episodio. Llama a `completion` en el hilo principal, y SOLO si el
    /// archivo llegó a guardarse de verdad (antes se avisaba "Descargado" y se marcaba como tal
    /// aunque la descarga hubiera fallado, dejando el episodio en un estado mentiroso).
    func download(_ episode: Episode, completion: @escaping () -> Void) {
        guard let url = episode.audioURL, !downloading.contains(episode.id) else { return }
        downloading.insert(episode.id)
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, _ in
            var success = false
            if let tempURL {
                let destination = DownloadManager.localURL(for: episode.id)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    success = true
                } catch { success = false }
            }
            DispatchQueue.main.async {
                self?.downloading.remove(episode.id)
                if success {
                    Notifications.notifyDownloaded(episode.id, episode.title, podcast: episode.podcastTitle)
                    completion()
                }
            }
        }.resume()
    }

    /// Borra el audio descargado de un episodio (al escucharlo y autoborrarlo, etc.).
    static func deleteFile(for episodeID: UUID) {
        try? FileManager.default.removeItem(at: localURL(for: episodeID))
    }
}
