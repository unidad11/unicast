import SwiftUI

/// Buscar y añadir podcasts: búsqueda real en el directorio de iTunes (por nombre),
/// o añadir pegando una URL / importando OPML.
struct SearchView: View {
    @Environment(AppStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isLoading = false
    @State private var followed: Set<Int> = []
    @State private var showAdd = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.background(store.backgroundStyle).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text("Buscar")
                    .font(displayFont(size: 26))
                    .foregroundStyle(Theme.textPrimary)

                searchField

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isLoading {
                            ProgressView().tint(Theme.accent).padding(.vertical, 20)
                        }
                        ForEach(results) { result in
                            resultRow(result)
                            Divider().overlay(Theme.divider)
                        }
                        addByURLRow
                    }
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showAdd) { AddPodcastView() }
        .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
        .onAppear {
            switch ProcessInfo.processInfo.environment["UNICAST_PREVIEW"] {
            case "addPodcast": showAdd = true
            case "search":
                query = "tecnología"
                searchTask = Task { await runSearch("tecnología") }
            default: break
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("", text: $query,
                      prompt: Text("Por nombre o pega una URL").foregroundStyle(Theme.textSecondary))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = ""; results = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func resultRow(_ result: SearchResult) -> some View {
        HStack(spacing: 11) {
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

    private var addByURLRow: some View {
        Button { showAdd = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "link").foregroundStyle(Theme.accent)
                Text("Añadir por URL o importar OPML")
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.textMuted)
            }
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Búsqueda

    private func scheduleSearch(_ term: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(term)
        }
    }

    private func runSearch(_ term: String) async {
        guard !term.trimmed.isEmpty else { results = []; return }
        isLoading = true
        let found = await PodcastService.search(term)
        guard !Task.isCancelled else { isLoading = false; return }
        results = found
        isLoading = false
    }

    private func follow(_ result: SearchResult) {
        guard let feed = result.feed else { return }
        followed.insert(result.id)
        Task {
            if let podcast = await PodcastService.fetchPodcast(
                feedURL: feed, colorHex: colorHexFor(result.collectionName)
            ) {
                store.subscribe(podcast, downloads: downloads)
            }
        }
    }
}
