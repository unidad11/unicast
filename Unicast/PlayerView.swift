import SwiftUI

/// Reproductor a pantalla completa, conectado al motor de audio real. La portada se toca
/// o se desliza para ver notas y capítulos. Controles de ±30 s; sin velocidad ni silencios.
struct PlayerView: View {
    @Environment(AppStore.self) private var store
    @Environment(AudioPlayer.self) private var audio
    @Environment(ColorExtractor.self) private var colors
    @State private var showNotes = false
    @State private var tint: Color?
    @State private var pulse = false
    @State private var appeared = false

    private var episode: Episode? { audio.currentEpisode ?? store.nowPlaying }
    private var total: TimeInterval {
        max(1, audio.duration > 0 ? audio.duration : (episode?.duration ?? 0))
    }

    var body: some View {
        ZStack {
            backgroundView

            if let episode {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 8)
                    cover(episode)
                    Spacer(minLength: 16)
                    info(episode)
                    progress
                    controls
                    Spacer(minLength: 16)
                    accessRow
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .sheet(isPresented: $showNotes) { NotesChaptersView(episode: episode) }
                .onAppear {
                    if ProcessInfo.processInfo.environment["UNICAST_PREVIEW"] == "player" {
                        audio.play(episode)
                    }
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { appeared = true }
                }
                .task(id: episode.id) {
                    let url = episode.artworkURL ?? podcastArtwork(for: episode)
                    await colors.load(url)
                    tint = colors.color(for: url) ?? ColorExtractor.soft(hex: episode.colorHex)
                }
            } else {
                Text("No hay nada sonando").foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Fondo del reproductor: teñido con el color de la portada (estilo Brink) o lavanda.
    private var backgroundView: some View {
        Group {
            if let tint {
                LinearGradient(colors: [tint, Color(hex: "DAD5E3")], startPoint: .top, endPoint: .bottom)
            } else {
                Theme.background()
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: tint)
    }

    private var topBar: some View {
        HStack {
            Button { store.isPlayerPresented = false } label: {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold))
            }
            Spacer()
            Text("REPRODUCIENDO")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 18))
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private func cover(_ ep: Episode) -> some View {
        Group {
            if let url = ep.artworkURL ?? podcastArtwork(for: ep) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { colorCover(ep) }
            } else {
                colorCover(ep)
            }
        }
        .frame(width: 260, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color(hex: ep.colorHex).opacity(0.45), radius: 28, x: 0, y: 16)
        .scaleEffect(appeared ? 1 : 0.7)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 70)   // entra subiendo y creciendo (evoca el "vuela")
        .contentShape(Rectangle())
        .onTapGesture { showNotes = true }
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -30 { showNotes = true }
            }
        )
    }

    private func colorCover(_ ep: Episode) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(hex: ep.colorHex))
            .overlay {
                Text(ep.podcastTitle)
                    .font(displayFont(size: 30))
                    .foregroundStyle(coverTextColor(forHex: ep.colorHex))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .padding(20)
            }
    }

    /// Carátula del podcast al que pertenece el episodio (si el feed la trae).
    private func podcastArtwork(for ep: Episode) -> URL? {
        store.podcasts.first { $0.title == ep.podcastTitle }?.artworkURL
    }

    private func info(_ ep: Episode) -> some View {
        VStack(spacing: 4) {
            Text(ep.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(ep.podcastTitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 14)
    }

    private var episodeSeed: Int { abs((episode?.id.hashValue ?? 7) % 100_000) }

    private var progress: some View {
        VStack(spacing: 8) {
            WaveformView(progress: audio.currentTime / total, seed: episodeSeed) { fraction in
                audio.seek(to: fraction * total)
            }
            .frame(height: 42)
            HStack {
                Text(formatClock(audio.currentTime))
                Spacer()
                Text("-" + formatClock(max(0, total - audio.currentTime)))
            }
            .font(monoFont(size: 12))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 18)
    }

    private var controls: some View {
        HStack(spacing: 30) {
            Button { audio.skip(by: -30) } label: {
                Image(systemName: "gobackward.30").font(.system(size: 30))
            }
            Button { audio.togglePlayPause() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(
                        LinearGradient(colors: [Theme.accent, Theme.accentDark],
                                       startPoint: .top, endPoint: .bottom), in: Circle())
                    .background(
                        Circle().stroke(Theme.accent, lineWidth: 2)
                            .scaleEffect(pulse ? 1.65 : 1)
                            .opacity(pulse ? 0 : 0.7)
                    )
                    .shadow(color: Theme.accent.opacity(0.4), radius: 14, y: 6)
            }
            Button { audio.skip(by: 30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 30))
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .onAppear { updatePulse() }
        .onChange(of: audio.isPlaying) { _, _ in updatePulse() }
    }

    /// Activa o detiene el latido del botón de play según si suena algo.
    private func updatePulse() {
        if audio.isPlaying {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        } else {
            pulse = false
        }
    }

    private var accessRow: some View {
        HStack(spacing: 44) {
            accessItem("list.bullet", "Capítulos") { showNotes = true }
            accessItem("doc.text", "Notas") { showNotes = true }
            VStack(spacing: 5) {
                AirPlayButton().frame(width: 28, height: 28)
                Text("AirPlay").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func accessItem(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 19))
                Text(label).font(.system(size: 11))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

/// Hoja con las notas del autor y los capítulos (con sus imágenes) del episodio.
struct NotesChaptersView: View {
    @Environment(AppStore.self) private var store
    let episode: Episode

    var body: some View {
        ZStack {
            Theme.background().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Group {
                            if let url = episode.artworkURL ?? store.podcasts.first(where: { $0.title == episode.podcastTitle })?.artworkURL {
                                AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color(hex: episode.colorHex) }
                            } else { Color(hex: episode.colorHex) }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(episode.podcastTitle)
                                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }

                    if !episode.chapters.isEmpty {
                        Text("Capítulos")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        ForEach(episode.chapters) { chapter in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(hex: chapter.colorHex))
                                    .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(formatClock(chapter.start))
                                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                    Text(chapter.title)
                                        .font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                                }
                                Spacer()
                            }
                        }
                    }

                    if !episode.summary.isEmpty {
                        Text("Notas del episodio")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary).padding(.top, 6)
                        Text(episode.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(3)
                    }
                }
                .padding(20)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
