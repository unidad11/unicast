import Foundation

/// Genera un OPML con los podcasts seguidos, para llevarlos a otra app o al Mac.
enum OPMLExporter {
    static func makeOPML(from podcasts: [Podcast]) -> String {
        let items = podcasts.compactMap { podcast -> String? in
            guard let feedURL = podcast.feedURL else { return nil }
            let title = escape(podcast.title)
            let author = escape(podcast.author)
            return "    <outline text=\"\(title)\" title=\"\(title)\" type=\"rss\" xmlUrl=\"\(feedURL.absoluteString)\" ownerName=\"\(author)\"/>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Podcasts de Unicast</title>
          </head>
          <body>
        \(items)
          </body>
        </opml>
        """
    }

    /// Escribe el OPML en un archivo temporal listo para compartir (AirDrop, correo, etc.).
    static func writeTempFile(from podcasts: [Podcast]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unicast_podcasts.opml")
        do {
            try makeOPML(from: podcasts).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
