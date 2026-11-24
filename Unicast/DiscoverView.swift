import SwiftUI

/// Descubrir: podcasts parecidos a los que sigues. Arriba, la «Selección de Claude» (hecha en el Mac mini con
/// la suscripción de Juan, comprobada en Apple y con una razón por podcast); debajo, las listas de más populares
/// de Apple por categoría y países, en español o en inglés (directorio de Apple, gratis).
struct DiscoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @State private var sections: [RecommendationSection] = []
    @State private var isLoading = true
    @State private var followed: Set<Int> = []
    @State private var language = "ES"   // ES = español, US = inglés
    @State private var errorText: String?
    @State private var picks = ClaudePicksService.shared
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var connecting = false

    var body: some View {
        ZStack {
            Theme.background().ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text("Descubrir")
                    .font(displayFont(size: 26)).foregroundStyle(Theme.textPrimary)

                Picker("Idioma", selection: $language) {
                    Text("Español").tag("ES")
                    Text("Inglés").tag("US")
                }
                .pickerStyle(.segmented)

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        claudeBlock
                        if isLoading {
                            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 20)
                        } else if sections.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "safari").font(.system(size: 38)).foregroundStyle(Theme.accent)
                                Text("Sigue algún podcast y aquí te propondré otros del mismo estilo, ordenados por categoría.")
                                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.center).padding(.horizontal, 30)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 20)
                        } else {
                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(section.genre)
                                        .font(displayFont(size: 19))
                                        .foregroundStyle(Theme.accent)
                                    if !section.basedOn.isEmpty {
                                        Text("Porque sigues: \(section.basedOn.joined(separator: ", "))")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(2)
                                            .padding(.bottom, 6)
                                    }
                                    ForEach(section.items) { item in
                                        resultRow(item)
                                        Divider().overlay(Theme.divider)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .padding(16)
        }
        .task(id: language) { await load(force: false) }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool) async {
        // La selección de Claude va aparte: no hace esperar a las listas de Apple.
        let podcasts = store.podcasts
        let idioma = language
        Task { await picks.refresh(podcasts: podcasts, language: idioma, force: force) }
        isLoading = true
        let seguidos = podcasts.map {
            FollowedPodcast(title: $0.title, summary: $0.summary, feedURL: $0.feedURL)
        }
        sections = await DescubrirEngine.recomendar(seguidos: seguidos, idioma: idioma)
        isLoading = false
    }

    // MARK: - Selección de Claude

    @ViewBuilder
    private var claudeBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Selección de Claude")
                    .font(displayFont(size: 19)).foregroundStyle(Theme.accent)
            }
            if !picks.isConfigured {
                configCard
            } else if let seleccion = picks.selection, !seleccion.items.isEmpty {
                Text("Elegida para ti según lo que escuchas · actualizada \(Self.hace(seleccion.fecha))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 4)
                ForEach(seleccion.items) { pick in
                    pickRow(pick)
                    Divider().overlay(Theme.divider)
                }
            } else if picks.isWaiting || picks.isWorking {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accent)
                    Text("Claude está preparando tu selección… puede tardar unos minutos.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text("Todavía no hay selección. Tira hacia abajo para pedirla.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if picks.isConfigured, let m = picks.message {
                Text(m).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude puede elegirte podcasts que encajen con lo que escuchas, con una razón para cada uno. Se prepara en tu Mac mini, así que necesita la dirección y la clave de sincronización (las mismas de Marcadores).")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("Dirección del servidor", text: $urlText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
            SecureField("Clave de sincronización", text: $tokenText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
            Button {
                connecting = true
                Task {
                    if await picks.connect(url: urlText, token: tokenText) {
                        tokenText = ""
                        await load(force: true)
                    }
                    connecting = false
                }
            } label: {
                Text(connecting ? "Conectando…" : "Conectar")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
            }
            .buttonStyle(.plain).disabled(connecting)
            if let m = picks.message {
                Text(m).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private func pickRow(_ pick: ClaudePick) -> some View {
        HStack(alignment: .top, spacing: 11) {
            AsyncImage(url: URL(string: pick.artwork)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface)
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(pick.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text(pick.author)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                Text(pick.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 6)
            followButton(pick.searchResult)
        }
        .padding(.vertical, 8)
    }

    private static func hace(_ fecha: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.unitsStyle = .full
        return f.localizedString(for: fecha, relativeTo: Date())
    }

    // MARK: - Listas de Apple

    private func resultRow(_ item: Recommendation) -> some View {
        let result = item.result
        return HStack(spacing: 11) {
            AsyncImage(url: result.artwork) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface)
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.collectionName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(result.artistName)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let rank = item.rankText {
                    Text(rank + (item.topicText.map { " · \($0)" } ?? ""))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent).lineLimit(1)
                }
            }
            Spacer()
            followButton(result)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func followButton(_ result: SearchResult) -> some View {
        let isFollowing = followed.contains(result.id) ||
            store.podcasts.contains { $0.title == result.collectionName }
        if isFollowing {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: "159E78"))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(hex: "E3F5EC")))
        } else {
            Button { follow(result) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().stroke(Theme.accent, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
    }

    private func follow(_ result: SearchResult) {
        guard let feed = result.feed else { return }
        errorText = nil
        // @MainActor: evita que este "seguir" se cruce con un refresco a la vez y el podcast se pierda.
        Task { @MainActor in
            if let podcast = await PodcastService.fetchPodcast(
                feedURL: feed, colorHex: colorHexFor(result.collectionName)
            ) {
                store.subscribe(podcast, downloads: downloads)
                followed.insert(result.id)   // solo se marca "seguido" si de verdad se guardó
            } else {
                errorText = "No se pudo añadir \"\(result.collectionName)\". Revisa tu conexión e inténtalo de nuevo."
            }
        }
    }
}
