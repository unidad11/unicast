import SwiftUI
import CryptoKit

/// Caché de imágenes (carátulas) en memoria + disco, para que se vean fijas sin internet
/// entre aperturas de la app. El archivo de cada URL se guarda en Caches/Covers con el
/// nombre siendo un hash estable de la URL (para poder reencontrarlo en el próximo arranque).
final class ImageCache {
    static let shared = ImageCache()

    private var memory: [URL: UIImage] = [:]
    private let folder: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func fileURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash)
    }

    /// Da la imagen para esa URL: de memoria, de disco, o la descarga y la guarda para la próxima vez.
    func image(for url: URL) async -> UIImage? {
        if let cached = memory[url] { return cached }
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory[url] = image
            return image
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data)
        else { return nil }
        memory[url] = image
        try? data.write(to: file)
        return image
    }
}

/// Como `AsyncImage`, pero pasando por `ImageCache`: una vez descargada, la carátula
/// queda fija en disco y se ve al momento aunque no haya conexión.
struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            uiImage = await ImageCache.shared.image(for: url)
        }
    }
}
