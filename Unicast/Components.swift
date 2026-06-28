import SwiftUI

/// Portada cuadrada de un podcast. Usa la imagen real (`artworkURL`); si no hay, un cuadro
/// con el color de categoría y el nombre encima.
struct PodcastCover: View {
    let podcast: Podcast
    var size: CGFloat = 80
    var showTitle: Bool = true

    var body: some View {
        Group {
            if let url = podcast.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    colorBlock
                }
            } else {
                colorBlock
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.21, style: .continuous))
    }

    private var colorBlock: some View {
        RoundedRectangle(cornerRadius: size * 0.21, style: .continuous)
            .fill(Color(hex: podcast.colorHex))
            .overlay {
                if showTitle {
                    Text(podcast.title)
                        .font(displayFont(size: max(9, size * 0.17)))
                        .foregroundStyle(coverTextColor(forHex: podcast.colorHex))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .padding(size * 0.1)
                }
            }
    }
}

/// Mini-reproductor: barra morada flotante con lo que suena.
struct MiniPlayer: View {
    @Environment(AppStore.self) private var store
    @Environment(AudioPlayer.self) private var audio
    let episode: Episode

    var body: some View {
        HStack(spacing: 11) {
            HStack(spacing: 11) {
                Group {
                    if let url = episode.artworkURL ?? store.podcasts.first(where: { $0.title == episode.podcastTitle })?.artworkURL {
                        AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { Color(hex: episode.colorHex) }
                    } else { Color(hex: episode.colorHex) }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(episode.podcastTitle) · quedan \(minutes(episode.remaining)) min")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.isPlayerPresented = true }

            Button { audio.togglePlayPause() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(
            LinearGradient(colors: [Theme.accent, Theme.accentDark], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .shadow(color: Theme.accent.opacity(0.35), radius: 16, x: 0, y: 8)
    }

    private func minutes(_ seconds: TimeInterval) -> Int { Int(seconds / 60) }
}

/// Celda de la vista "Mazos": portada del podcast con cartas asomando por detrás
/// cuando tiene varios episodios (estilo Brink). Nombre en fuente con carácter.
struct PodcastDeck: View {
    let podcast: Podcast
    @State private var bob = false
    private var hasSeveral: Bool { podcast.episodes.count > 1 }

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                if hasSeveral {
                    card.rotationEffect(.degrees(-9)).offset(x: -14, y: -6)
                    card.rotationEffect(.degrees(9)).offset(x: 14, y: -6)
                }
                PodcastCover(podcast: podcast, size: 104)
                    .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 10)
            }
            .frame(height: 122)
            .offset(y: bob ? -7 : 0)   // flotación suave (estilo Brink)
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(bobDelay), value: bob)
            Text(podcast.title)
                .font(displayFont(size: 17))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .onAppear { bob = true }
    }

    /// Pequeño desfase por podcast para que las cartas no floten todas a la vez.
    private var bobDelay: Double { Double(abs(podcast.id.hashValue) % 13) / 10.0 }

    private var card: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(Color(hex: podcast.colorHex).opacity(0.9))
            .frame(width: 90, height: 104)
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 5)
    }
}

/// Fila de la vista "Lista": portada pequeña, nombre y autor.
struct PodcastListRow: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            PodcastCover(podcast: podcast, size: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(podcast.author)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 8)
    }
}

/// Onda de sonido del reproductor: barras verticales donde la parte ya reproducida va en color.
/// Se puede arrastrar sobre ella para avanzar o retroceder.
struct WaveformView: View {
    let progress: Double          // fracción reproducida (0...1)
    let seed: Int
    let onSeek: (Double) -> Void
    private let bars = 46

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / Double(bars) <= progress ? Theme.accent : Theme.textMuted.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(4, geo.size.height * height(i)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onSeek(min(1, max(0, v.location.x / geo.size.width))) }
            )
        }
    }

    /// Altura pseudo-aleatoria pero estable para cada barra (sin generador, solo una fórmula).
    private func height(_ i: Int) -> CGFloat {
        let x = sin(Double(i) * 12.9898 + Double(seed % 1000)) * 43758.5453
        return 0.28 + 0.72 * CGFloat(x - floor(x))
    }
}

/// Elige texto oscuro o blanco según lo claro que sea el color de fondo.
func coverTextColor(forHex hex: String) -> Color {
    let clean = hex.replacingOccurrences(of: "#", with: "")
    var rgb: UInt64 = 0
    Scanner(string: clean).scanHexInt64(&rgb)
    let r = Double((rgb >> 16) & 0xFF) / 255
    let g = Double((rgb >> 8) & 0xFF) / 255
    let b = Double(rgb & 0xFF) / 255
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b
    return luminance > 0.6 ? Color(hex: "3A3500") : .white
}

/// Color de portada estable a partir del nombre (respaldo cuando no hay imagen).
func colorHexFor(_ name: String) -> String {
    let palette = ["F2E14B", "C2E04B", "E24B4A", "E8743B", "159E78", "2D6CDF", "5B5BD6", "C94F86"]
    let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[sum % palette.count]
}
