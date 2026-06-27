import SwiftUI

/// Portada cuadrada de un podcast (estilo carta). Mientras no haya imagen real del autor,
/// se dibuja con el color del podcast y su nombre encima.
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
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
    }

    /// Relleno de color con el nombre encima, cuando no hay imagen del autor.
    private var colorBlock: some View {
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .fill(Color(hex: podcast.colorHex))
            .overlay {
                if showTitle {
                    Text(podcast.title)
                        .font(.system(size: max(9, size * 0.17), weight: .heavy))
                        .foregroundStyle(coverTextColor(forHex: podcast.colorHex))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .padding(size * 0.1)
                }
            }
    }
}

/// Elige un color de portada estable a partir del nombre (fallback cuando no hay imagen).
func colorHexFor(_ name: String) -> String {
    let palette = ["F2E14B", "C2E04B", "E24B4A", "2D6CDF", "E8743B", "159E78", "5B5BD6", "C94F86"]
    let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[sum % palette.count]
}

/// Mini-reproductor que se ve en la parte de abajo: lo que está sonando ahora.
struct MiniPlayer: View {
    @Environment(AppStore.self) private var store
    @Environment(AudioPlayer.self) private var audio
    let episode: Episode

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if let url = episode.artworkURL ?? store.podcasts.first(where: { $0.title == episode.podcastTitle })?.artworkURL {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { Color(hex: episode.colorHex) }
                    } else {
                        Color(hex: episode.colorHex)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(episode.podcastTitle) · quedan \(minutes(episode.remaining)) min")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "DCD7FF"))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.isPlayerPresented = true }   // abre el reproductor grande

            Button { audio.togglePlayPause() } label: {        // pausa/reproduce aquí mismo
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func minutes(_ seconds: TimeInterval) -> Int { Int(seconds / 60) }
}

/// Elige texto oscuro o blanco según lo claro que sea el color de fondo, para que se lea.
func coverTextColor(forHex hex: String) -> Color {
    let clean = hex.replacingOccurrences(of: "#", with: "")
    var rgb: UInt64 = 0
    Scanner(string: clean).scanHexInt64(&rgb)
    let r = Double((rgb >> 16) & 0xFF) / 255
    let g = Double((rgb >> 8) & 0xFF) / 255
    let b = Double(rgb & 0xFF) / 255
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b
    return luminance > 0.6 ? Color(hex: "1A1500") : .white
}

/// Celda de la vista "Mazos": la portada del podcast con cartas asomando por detrás
/// cuando tiene varios episodios (estilo Brink). El nombre va en fuente con carácter.
struct PodcastDeck: View {
    let podcast: Podcast
    private var hasSeveral: Bool { podcast.episodes.count > 1 }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if hasSeveral {
                    card.brightness(-0.10).rotationEffect(.degrees(-9)).offset(x: -14, y: -7)
                    card.brightness(-0.10).rotationEffect(.degrees(9)).offset(x: 14, y: -7)
                }
                PodcastCover(podcast: podcast, size: 104)
                    .overlay(
                        RoundedRectangle(cornerRadius: 104 * 0.16, style: .continuous)
                            .stroke(Color(hex: "0A0A0B"), lineWidth: 2)
                    )
            }
            .frame(height: 122)
            Text(podcast.title)
                .font(displayFont(size: 17))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color(hex: podcast.colorHex))
            .frame(width: 90, height: 104)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color(hex: "0A0A0B"), lineWidth: 2)
            )
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
                    .foregroundStyle(.white).lineLimit(1)
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
