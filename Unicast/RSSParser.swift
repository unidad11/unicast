import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Parsea un feed RSS de podcast con `XMLParser` (de Foundation, sin dependencias externas)
/// y devuelve un `Podcast` con sus episodios: título, autor, resumen, audio, duración,
/// fecha, imagen y capítulos (formato Podlove Simple Chapters).
final class RSSParser: NSObject, XMLParserDelegate {
    private let feedURL: URL?
    private let colorHex: String

    // Datos del canal (el podcast)
    private var channelTitle = ""
    private var channelAuthor = ""
    private var channelSummary = ""
    private var channelImage: URL?

    private var episodes: [Episode] = []

    // Estado de parseo
    private var text = ""
    private var inItem = false
    private var inChannelImage = false

    // Datos del episodio en curso
    private var iTitle = ""
    private var iSummary = ""
    private var iAudio: URL?
    private var iDuration: TimeInterval = 0
    private var iDate = Date()
    private var iImage: URL?
    private var iChapters: [Chapter] = []

    init(feedURL: URL?, colorHex: String = "5B5BD6") {
        self.feedURL = feedURL
        self.colorHex = colorHex
    }

    /// Parsea los datos del feed. Devuelve el podcast, o nil si no hubo título.
    func parse(data: Data) -> Podcast? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        let podcast = Podcast(
            title: channelTitle.trimmed,
            author: channelAuthor.trimmed,
            summary: stripHTML(channelSummary).trimmed,
            feedURL: feedURL,
            colorHex: colorHex,
            artworkURL: channelImage,
            episodes: episodes
        )
        return podcast.title.isEmpty ? nil : podcast
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "item":
            inItem = true
            iTitle = ""; iSummary = ""; iAudio = nil; iDuration = 0
            iDate = Date(); iImage = nil; iChapters = []
        case "image" where !inItem:
            inChannelImage = true
        case "enclosure":
            if let urlString = attributeDict["url"], let url = URL(string: urlString) { iAudio = url }
        case "itunes:image":
            if let href = attributeDict["href"], let url = URL(string: href) {
                if inItem { iImage = url } else { channelImage = url }
            }
        case "psc:chapter":
            if let start = attributeDict["start"], let title = attributeDict["title"] {
                iChapters.append(Chapter(title: title, start: timecode(start), colorHex: colorHex))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmed
        if inItem {
            switch elementName {
            case "title": iTitle = value
            case "description", "itunes:summary", "content:encoded":
                if iSummary.isEmpty { iSummary = stripHTML(value) }
            case "itunes:duration": iDuration = duration(value)
            case "pubDate": iDate = pubDate(value) ?? iDate
            case "item":
                episodes.append(Episode(
                    title: iTitle, summary: iSummary.trimmed, podcastTitle: channelTitle.trimmed,
                    colorHex: colorHex, artworkURL: iImage ?? channelImage, audioURL: iAudio,
                    duration: iDuration, publishedAt: iDate, chapters: iChapters
                ))
                inItem = false
            default:
                break
            }
        } else {
            switch elementName {
            case "title": if channelTitle.isEmpty { channelTitle = value }
            case "itunes:author", "author", "managingEditor":
                if channelAuthor.isEmpty { channelAuthor = value }
            case "description", "itunes:summary":
                if channelSummary.isEmpty { channelSummary = value }
            case "url":
                if inChannelImage, channelImage == nil { channelImage = URL(string: value) }
            case "image":
                inChannelImage = false
            default:
                break
            }
        }
        text = ""
    }

    // MARK: - Helpers

    /// "3600", "48:00" o "1:02:00" → segundos.
    private func duration(_ string: String) -> TimeInterval {
        if string.contains(":") {
            return string.split(separator: ":").map { Double($0) ?? 0 }.reduce(0) { $0 * 60 + $1 }
        }
        return Double(string) ?? 0
    }

    private func timecode(_ string: String) -> TimeInterval { duration(string) }

    /// Fecha RFC-822 (pubDate) o ISO-8601.
    private func pubDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                       "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    /// Quita etiquetas HTML básicas de las descripciones.
    private func stripHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
