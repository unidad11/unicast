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
    /// Se llama cuando se han descargado los capítulos de un episodio, para que se guarden en disco.
    @ObservationIgnored var onChaptersLoaded: ((UUID, [Chapter]) -> Void)?
    @ObservationIgnored private var artworkImage: UIImage?
    /// El objeto de portada ya construido para el Now Playing (pantalla de bloqueo / isla): se crea
    /// una sola vez por imagen, no en cada actualización (cada medio segundo), para que un cambio
    /// de imagen entre capítulos se vea limpio en vez de reconstruirse sin necesidad.
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
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
        ) { [weak self] notification in
            guard let self, let id = self.currentEpisode?.id else { return }
            // Hay que mirar QUÉ item ha terminado. La notificación la manda el propio AVPlayerItem
            // y puede llegar con retraso; si en ese hueco el usuario ha cambiado de episodio, sin
            // este filtro se daba por terminado —y se BORRABA— el episodio recién elegido, que no
            // había sonado ni un segundo.
            guard let item = notification.object as? AVPlayerItem,
                  item === self.player.currentItem else { return }
            self.isPlaying = false
            self.onFinished?(id)
        }
        // Al quitarse los AirPods (o quedarse sin batería, o salir de rango) iOS pasa la salida al
        // altavoz del iPhone. Sin esto, el podcast seguía sonando a todo volumen por el altavoz:
        // el susto clásico en el metro. La categoría .playback NO hace esto sola.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            self.player.pause()
            self.isPlaying = false
            self.savePosition()
            self.updateNowPlaying()
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
        // Guarda dónde se quedó el anterior ANTES de cambiar. Sin esto, cambiar de episodio sin
        // pausar perdía hasta 30 s de progreso (lo que va de un guardado automático al siguiente).
        if let current = currentEpisode, current.id != episode.id { savePosition() }
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
            observeStatus(of: item, seekTo: episode.playbackPosition)
        } else {
            // Un episodio sin audio (feed sin <enclosure>, o URL ilegible) NO puede dejar cargado
            // el item anterior: seguiría sonando el episodio de antes con la identidad del nuevo,
            // y el autoborrado acabaría borrando un episodio que el usuario no ha escuchado.
            clearPlayerItem()
        }
        lastSavedTime = episode.playbackPosition
        isPlaying = false
        refreshArtworkIfNeeded()
        updateNowPlaying()
        loadChaptersIfNeeded()
    }

    /// Actualiza los capítulos del episodio en curso (p.ej. tras descargarlos del JSON aparte)
    /// y refresca la portada al momento si toca cambiar de imagen.
    func updateChapters(_ chapters: [Chapter], for episodeID: UUID) {
        guard currentEpisode?.id == episodeID else { return }
        currentEpisode?.chapters = chapters
        refreshArtworkIfNeeded()
    }

    /// Si el episodio trae capítulos en un JSON aparte (Podcasting 2.0) que aún no se han pedido,
    /// los descarga ya al prepararlo. Antes solo se pedían al abrir la hoja de "Capítulos", así que
    /// hasta que el usuario la abría, la portada (también la del Now Playing: pantalla de bloqueo
    /// e isla) se quedaba siempre con el logo del podcast en vez de la imagen de cada sección.
    private func loadChaptersIfNeeded() {
        guard let episode = currentEpisode, episode.chapters.isEmpty, let url = episode.chaptersURL else { return }
        let episodeID = episode.id
        let colorHex = episode.colorHex
        Task { [weak self] in
            let chapters = await PodcastService.fetchChapters(from: url, colorHex: colorHex)
            guard !chapters.isEmpty else { return }
            await MainActor.run {
                self?.onChaptersLoaded?(episodeID, chapters)
                self?.updateChapters(chapters, for: episodeID)
            }
        }
    }

    /// Reproduce un episodio (desde donde se quedó).
    func play(_ episode: Episode) {
        try? AVAudioSession.sharedInstance().setActive(true)
        if currentEpisode?.id != episode.id { prepare(episode) }
        // Sin nada cargado no hay nada que reproducir: no dejes la app diciendo que suena.
        guard player.currentItem != nil else {
            isPlaying = false
            updateNowPlaying()
            return
        }
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
    private func observeStatus(of item: AVPlayerItem, seekTo seconds: TimeInterval) {
        statusObservation?.invalidate()
        statusObservation = nil
        pendingSeek = seconds > 0 ? seconds : nil
        // El vigía se instala SIEMPRE, también cuando el episodio empieza desde cero. Antes solo se
        // ponía si había una posición guardada a la que saltar, así que un archivo corrupto o una
        // URL caída en un episodio que se estrenaba dejaban la app diciendo "reproduciendo" para
        // siempre: sin sonido, sin barra que avanzara y sin ningún aviso.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            guard status == .readyToPlay || status == .failed else { return }
            DispatchQueue.main.async {
                // Si mientras tanto se ha cambiado de episodio, esto ya no va con nosotros.
                guard let self, self.player.currentItem === item else { return }
                let target = self.pendingSeek
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
                guard let target else {
                    // Listo y sin salto pendiente: si estaba esperando para sonar, que suene.
                    if self.playWhenSeekCompletes {
                        self.playWhenSeekCompletes = false
                        self.player.playImmediately(atRate: 1.0)
                    }
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

    /// Vacía el reproductor y cancela lo que estuviera pendiente.
    private func clearPlayerItem() {
        statusObservation?.invalidate()
        statusObservation = nil
        pendingSeek = nil
        playWhenSeekCompletes = false
        player.replaceCurrentItem(with: nil)
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
        // Arrastrar la barra desde la pantalla de bloqueo, el centro de control o el coche. iOS
        // pintaba la barra igualmente (porque se publican tiempo y duración), pero al arrastrarla
        // volvía sola a su sitio: no había nadie atendiendo la orden.
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: event.positionTime)
            return .success
        }
    }

    /// Decide qué imagen toca mostrar ahora (la de la sección en curso, o si no, la del episodio)
    /// y solo recarga si de verdad ha cambiado (evita pedir la misma imagen cada medio segundo).
    private func refreshArtworkIfNeeded() {
        let target = currentChapterArtworkURL ?? currentEpisode?.artworkURL
        guard target != lastArtworkURL else { return }
        lastArtworkURL = target
        loadArtwork(target)
    }

    /// Descarga la carátula (pasando por la caché de disco compartida, para no repetir la
    /// petición si ya se había visto esa imagen antes) y refresca la info de la pantalla de
    /// bloqueo / isla.
    private func loadArtwork(_ url: URL?) {
        artworkImage = nil
        nowPlayingArtwork = nil
        guard let url else { updateNowPlaying(); return }
        Task { [weak self] in
            guard let image = await ImageCache.shared.image(for: url) else { return }
            await MainActor.run {
                // Si mientras bajaba ya tocaba mostrar otra imagen (cambio de capítulo), se descarta.
                guard let self, self.lastArtworkURL == url else { return }
                self.artworkImage = image
                self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlaying()
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
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
