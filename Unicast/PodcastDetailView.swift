import SwiftUI

/// Pantalla de dentro de un podcast: cabecera con portada, resumen del autor,
/// pestañas Descargados / Todos y la lista de episodios. Con "Seleccionar" se marcan
/// varios episodios para enviarlos a una lista o borrarlos de golpe. Tema claro.
struct PodcastDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(AudioPlayer.self) private var audio
    @Environment(ColorExtractor.self) private var colors
    let podcast: Podcast

    @State private var tab: PodcastTab = .downloaded
    @State private var showSettings = false
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var showAddToPlaylist = false
    @State private var tint: Color?

    private var current: Podcast { store.podcast(id: podcast.id) ?? podcast }

    private var episodes: [Episode] {
        let base = tab == .downloaded ? current.downloadedEpisodes : current.feedEpisodes
        return current.sortOrder == .newest
            ? base.sorted { $0.publishedAt > $1.publishedAt }
            : base.sorted { $0.publishedAt < $1.publishedAt }
    }

    var body: some View {
        ZStack {
            backgroundView

            VStack(spacing: 0) {
                List {
                    headerSection
                    episodesSection
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)

                if isSelecting && !selected.isEmpty {
                    selectionBar
                } else if tab == .downloaded, let episode = audio.currentEpisode ?? store.nowPlaying {
                    MiniPlayer(episode: episode)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("Listo") { isSelecting = false; selected = [] }
                } else {
                    Button { showSettings = true } label: {
                        Image(systemName: "ellipsis").foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) {
            NavigationStack { PodcastSettingsView(podcastID: podcast.id) }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistView(episodeIDs: Array(selected)) { isSelecting = false; selected = [] }
        }
        .onAppear {
            let preview = ProcessInfo.processInfo.environment["UNICAST_PREVIEW"]
            if preview == "podcastSettings" {
                showSettings = true
            } else if preview == "select" {
                isSelecting = true
                selected = Set(episodes.prefix(2).map(\.id))
            }
        }
        .task(id: current.id) {
            await colors.load(current.artworkURL)
            tint = colors.color(for: current.artworkURL) ?? ColorExtractor.soft(hex: current.colorHex)
        }
    }

    /// Fondo teñido con el color del podcast (cabecera estilo Brink) que baja a lavanda.
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

    // MARK: - Cabecera

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 13) {
                    PodcastCover(podcast: current, size: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.title)
                            .font(displayFont(size: 22)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        Text("\(current.author) · \(current.episodes.count) episodios")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                if !current.summary.isEmpty {
                    Text(current.summary)
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2).lineSpacing(1)
                }

                Picker("", selection: $tab) {
                    ForEach(PodcastTab.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    if isSelecting {
                        Button(selected.count == episodes.count && !episodes.isEmpty ? "Ninguno" : "Todos") {
                            if selected.count == episodes.count { selected = [] }
                            else { selected = Set(episodes.map(\.id)) }
                        }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        .buttonStyle(.borderless)   // independiente dentro de la List (clave del bug)
                    } else {
                        Label(current.sortOrder.label, systemImage: "arrow.up.arrow.down")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button(isSelecting ? "Cancelar" : "Seleccionar") {
                        isSelecting.toggle()
                        if !isSelecting { selected = [] }
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    .buttonStyle(.borderless)   // independiente dentro de la List
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Episodios

    private var episodesSection: some View {
        Section {
            if episodes.isEmpty {
                Text(tab == .downloaded ? "No hay episodios descargados." : "Estás al día.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } else {
                ForEach(episodes) { episode in
                    EpisodeRow(episode: episode, tab: tab, podcastID: current.id,
                               isSelecting: isSelecting, isSelected: selected.contains(episode.id)) {
                        toggle(episode.id)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if tab == .downloaded && !isSelecting {
                            Button(role: .destructive) {
                                store.removeEpisode(episode.id, from: current.id)
                            } label: { Label("Borrar", systemImage: "trash") }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Barra de acciones de selección

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button { showAddToPlaylist = true } label: {
                Label("Añadir a lista", systemImage: "text.badge.plus")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button { store.removeEpisodes(selected, from: current.id); isSelecting = false; selected = [] } label: {
                Label("Borrar (\(selected.count))", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: "D23A39"))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color(hex: "FBE6E6"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.bottom, 8).padding(.top, 4)
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

/// Una fila de episodio. En modo selección muestra una casilla y al tocar la marca.
private struct EpisodeRow: View {
    @Environment(AppStore.self) private var store
    @Environment(AudioPlayer.self) private var audio
    @Environment(DownloadManager.self) private var downloads
    let episode: Episode
    let tab: PodcastTab
    let podcastID: UUID
    let isSelecting: Bool
    let isSelected: Bool
    let onToggle: () -> Void

    private var inProgress: Bool { episode.playbackPosition > 0 }

    private var metaLine: String {
        if tab == .downloaded && inProgress {
            return "\(relativeDay(episode.publishedAt)) · quedan \(Int(episode.remaining / 60)) min"
        }
        if episode.isPlayed {
            return "\(relativeDay(episode.publishedAt)) · Escuchado"
        }
        return "\(relativeDay(episode.publishedAt)) · \(formatDuration(episode.duration))"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textMuted)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(inProgress ? Theme.accent : Theme.textSecondary)
                Text(episode.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(audio.currentEpisode?.id == episode.id ? Theme.accent : Theme.textPrimary)
                    .lineLimit(2)
                if !episode.summary.isEmpty {
                    Text(episode.summary)
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !isSelecting { actionButton }
        }
        .padding(.vertical, 11)
        .opacity(episode.isPlayed && !isSelecting ? 0.45 : 1)   // escuchado: tono apagado
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                onToggle()
            } else {
                let ep = store.enrich(episode)
                store.nowPlaying = ep
                audio.play(ep)
                store.isPlayerPresented = true
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if tab == .downloaded {
            Button { let ep = store.enrich(episode); store.nowPlaying = ep; audio.play(ep); store.isPlayerPresented = true } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(inProgress ? .white : Theme.accent)
                    .frame(width: 33, height: 33)
                    .background {
                        if inProgress { Circle().fill(Theme.accent) }
                        else { Circle().stroke(Theme.textMuted, lineWidth: 1.5) }
                    }
            }
            .buttonStyle(.plain)
        } else if downloads.downloading.contains(episode.id) {
            ProgressView().tint(Theme.accent).frame(width: 33, height: 33)
        } else {
            Button {
                downloads.download(episode) { store.markDownloaded(episode.id, in: podcastID) }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 14)).foregroundStyle(Theme.accent)
                    .frame(width: 33, height: 33)
                    .background { Circle().stroke(Theme.textMuted, lineWidth: 1.5) }
            }
            .buttonStyle(.plain)
        }
    }
}
