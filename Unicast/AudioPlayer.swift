import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import Observation

/// Motor de reproducción de audio (AVFoundation). Reproduce el episodio, lleva el tiempo,
/// y publica la info en la pantalla de bloqueo / isla (MPNowPlayingInfoCenter) y atiende
/// los controles del sistema y AirPods (MPRemoteCommandCenter): play/pausa y ±30 s.
@Observable
final class AudioPlayer {
    private(set) var currentEpisode: Episode?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    /// Se llama cuando un episodio llega al final (para autoborrarlo).
    @ObservationIgnored var onFinished: ((UUID) -> Void)?
    @ObservationIgnored private var artworkImage: UIImage?

    init() {
        configureSession()
        addTimeObserver()
        setupRemoteCommands()
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let id = self.currentEpisode?.id else { return }
            self.isPlaying = false
            self.onFinished?(id)
        }
    }

    /// Carga un episodio sin reproducir (para "recordar el último" al abrir la app).
    func prepare(_ episode: Episode) {
        currentEpisode = episode
        loadArtwork(episode.artworkURL)
        duration = episode.duration
        currentTime = episode.playbackPosition
        // Si está descargado, reproduce el archivo local; si no, hace streaming.
        let source = DownloadManager.isDownloaded(episode.id)
            ? DownloadManager.localURL(for: episode.id) : episode.audioURL
        if let url = source {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            seekPlayer(to: episode.playbackPosition)
        }
        isPlaying = false
        updateNowPlaying()
    }

    /// Reproduce un episodio (desde donde se quedó).
    func play(_ episode: Episode) {
        try? AVAudioSession.sharedInstance().setActive(true)
        if currentEpisode?.id != episode.id { prepare(episode) }
        player.playImmediately(atRate: 1.0)   // arranca en cuanto el audio esté listo
        isPlaying = true
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying.toggle()
        if isPlaying { player.play() } else { player.pause() }
        updateNowPlaying()
    }

    /// Lleva la reproducción a un segundo concreto (la barra de progreso).
    func seek(to seconds: TimeInterval) {
        currentTime = min(max(0, seconds), duration)
        seekPlayer(to: currentTime)
        updateNowPlaying()
    }

    /// Salta hacia delante o atrás (±30 s).
    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    // MARK: - Privado

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func seekPlayer(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let itemDuration = self.player.currentItem?.duration.seconds,
               itemDuration.isFinite, itemDuration > 0 {
                self.duration = itemDuration
            }
            self.updateNowPlaying()
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skip(by: 30); return .success }
        center.skipBackwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(by: -30); return .success }
        // Algunos AirPods/mandos mandan next/previous: los tratamos como ±30 s.
        center.nextTrackCommand.addTarget { [weak self] _ in self?.skip(by: 30); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.skip(by: -30); return .success }
    }

    /// Descarga la carátula y refresca la info de la pantalla de bloqueo / isla.
    private func loadArtwork(_ url: URL?) {
        artworkImage = nil
        guard let url else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                self?.artworkImage = image
                self?.updateNowPlaying()
            }
        }
    }

    private func updateNowPlaying() {
        guard let episode = currentEpisode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcastTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        if let image = artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
