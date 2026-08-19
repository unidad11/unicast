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
    /// Se llama para ir guardando la posición: al pausar y cada poco mientras suena.
    @ObservationIgnored var onPositionUpdate: ((UUID, TimeInterval) -> Void)?
    @ObservationIgnored private var artworkImage: UIImage?
    @ObservationIgnored private var lastArtworkURL: URL?
    /// Salto pendiente hasta que el audio esté listo, y el vigía que avisa de que ya lo está.
    @ObservationIgnored private var pendingSeek: TimeInterval?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// ¿Hay que empezar a sonar en cuanto termine ese salto pendiente?
    @ObservationIgnored private var playWhenSeekCompletes = false
    /// Última posición que se mandó guardar (para no escribir en disco a cada instante).
    @ObservationIgnored private var lastSavedTime: TimeInterval = 0

    /// Imagen de la sección que suena ahora mismo (según el minuto actual), si el episodio trae capítulos con imagen.
    var currentChapterArtworkURL: URL? {
        guard let chapters = currentEpisode?.chapters, !chapters.isEmpty else { return nil }
        return chapters.filter { $0.start <= currentTime }.max(by: { $0.start < $1.start })?.imageURL
    }

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
        // Llamadas, avisos de Siri, etc.: sin esto, al colgar el sistema puede darle el control
        // a otra app (Apple Music) en vez de devolvérselo a Unicast.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
    }

    /// Carga un episodio sin reproducir (para "recordar el último" al abrir la app).
    func prepare(_ episode: Episode) {
        currentEpisode = episode
        lastArtworkURL = nil
        duration = episode.duration
        currentTime = episode.playbackPosition
        // Si está descargado, reproduce el archivo local; si no, hace streaming.
        let source = DownloadManager.isDownloaded(episode.id)
            ? DownloadManager.localURL(for: episode.id) : episode.audioURL
        if let url = source {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            seekWhenReady(item, to: episode.playbackPosition)
        }
        lastSavedTime = episode.playbackPosition
        isPlaying = false
        refreshArtworkIfNeeded()
        updateNowPlaying()
    }

    /// Actualiza los capítulos del episodio en curso (p.ej. tras descargarlos del JSON aparte)
    /// y refresca la portada al momento si toca cambiar de imagen.
    func updateChapters(_ chapters: [Chapter], for episodeID: UUID) {
        guard currentEpisode?.id == episodeID else { return }
        currentEpisode?.chapters = chapters
        refreshArtworkIfNeeded()
    }

    /// Reproduce un episodio (desde donde se quedó).
    func play(_ episode: Episode) {
        try? AVAudioSession.sharedInstance().setActive(true)
        if currentEpisode?.id != episode.id { prepare(episode) }
        // Si aún falta colocar el episodio donde se dejó, espera a ese salto para sonar: si no,
        // se oiría un instante del principio y después el brinco.
        if pendingSeek != nil {
            playWhenSeekCompletes = true
        } else {
            player.playImmediately(atRate: 1.0)   // arranca en cuanto el audio esté listo
        }
        isPlaying = true
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying.toggle()
        if isPlaying {
            player.play()
        } else {
            player.pause()
            savePosition()   // al pausar, apunta ya dónde se quedó
        }
        updateNowPlaying()
    }

    /// Lleva la reproducción a un segundo concreto (la barra de progreso).
    func seek(to seconds: TimeInterval) {
        currentTime = min(max(0, seconds), duration)
        seekPlayer(to: currentTime)
        refreshArtworkIfNeeded()
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

    /// Lleva el reproductor a un segundo concreto. `precise` (sin margen de tolerancia) se usa al
    /// retomar un episodio: con el margen por defecto iOS puede dejarlo caer unos segundos antes,
    /// que es justo lo que se notaba en los episodios largos.
    private func seekPlayer(to seconds: TimeInterval, precise: Bool = false, completion: (() -> Void)? = nil) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if precise {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async { completion?() }
            }
        } else {
            player.seek(to: target)
            completion?()
        }
    }

    /// Salta a la posición guardada, pero SOLO cuando el audio esté de verdad listo.
    /// A un mp3 de varias horas le lleva un instante leer su índice interno; si se le pide el salto
    /// antes de tiempo, iOS lo descarta sin avisar y el episodio arranca donde le parece.
    private func seekWhenReady(_ item: AVPlayerItem, to seconds: TimeInterval) {
        statusObservation?.invalidate()
        statusObservation = nil
        pendingSeek = nil
        guard seconds > 0 else { return }
        pendingSeek = seconds
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            guard status == .readyToPlay || status == .failed else { return }
            DispatchQueue.main.async {
                guard let self, let target = self.pendingSeek else { return }
                self.pendingSeek = nil
                self.statusObservation?.invalidate()
                self.statusObservation = nil
                // Si el archivo no se puede abrir, no dejes la app diciendo que suena.
                guard status == .readyToPlay else {
                    self.playWhenSeekCompletes = false
                    self.isPlaying = false
                    self.updateNowPlaying()
                    return
                }
                self.seekPlayer(to: target, precise: true) { [weak self] in
                    guard let self, self.playWhenSeekCompletes else { return }
                    self.playWhenSeekCompletes = false
                    self.player.playImmediately(atRate: 1.0)
                }
            }
        }
    }

    /// Manda guardar dónde va la reproducción (la app lo escribe en disco).
    private func savePosition() {
        guard let id = currentEpisode?.id, currentTime > 0 else { return }
        lastSavedTime = currentTime
        onPositionUpdate?(id, currentTime)
    }

    /// Al empezar la interrupción (llamada, etc.) el sistema ya pausa el audio por su cuenta;
    /// aquí solo reflejamos ese pausado. Al terminar, si el sistema dice que es buen momento
    /// para seguir (`.shouldResume`), Unicast recupera el control y sigue sonando solo.
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            isPlaying = false
            updateNowPlaying()
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            updateNowPlaying()
        @unknown default:
            break
        }
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
            // Guarda la posición cada 30 s: si la app se cierra de golpe, no se pierde el sitio.
            if self.isPlaying, abs(self.currentTime - self.lastSavedTime) >= 30 { self.savePosition() }
            self.refreshArtworkIfNeeded()
            self.updateNowPlaying()
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Play y pausa son órdenes concretas, no un interruptor: si ambas alternaban, unos AirPods
        // o el coche podían mandar "play" estando ya sonando... y pausarlo.
        center.playCommand.addTarget { [weak self] _ in
            guard let self, !self.isPlaying else { return .success }
            self.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying else { return .success }
            self.togglePlayPause()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skip(by: 30); return .success }
        center.skipBackwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(by: -30); return .success }
        // Algunos AirPods/mandos mandan next/previous: los tratamos como ±30 s.
        center.nextTrackCommand.addTarget { [weak self] _ in self?.skip(by: 30); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.skip(by: -30); return .success }
    }

    /// Decide qué imagen toca mostrar ahora (la de la sección en curso, o si no, la del episodio)
    /// y solo recarga si de verdad ha cambiado (evita pedir la misma imagen cada medio segundo).
    private func refreshArtworkIfNeeded() {
        let target = currentChapterArtworkURL ?? currentEpisode?.artworkURL
        guard target != lastArtworkURL else { return }
        lastArtworkURL = target
        loadArtwork(target)
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
