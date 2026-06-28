import SwiftUI

/// Descubrir: podcasts parecidos a los que sigues, por género (directorio de Apple, gratis).
struct DiscoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @State private var results: [SearchResult] = []
    @State private var isLoading = true
    @State private var followed: Set<Int> = []

    var body: some View {
        ZStack {
            Theme.background().ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text("Descubrir")
                    .font(displayFont(size: 26)).foregroundStyle(Theme.textPrimary)
                Text("Parecidos a los que sigues")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)

                if isLoading {
                    Spacer()
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "safari").font(.system(size: 38)).foregroundStyle(Theme.accent)
                        Text("Sigue algún podcast y aquí te propondré otros del mismo estilo.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { result in
                                resultRow(result)
                                Divider().overlay(Theme.divider)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if results.isEmpty { isLoading = true }
        results = await PodcastService.discover(from: store.podcasts)
        isLoading = false
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
