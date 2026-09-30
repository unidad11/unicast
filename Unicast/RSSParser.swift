import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension URL {
    /// Sube http:// a https:// (iOS bloquea las conexiones sin cifrar); casi todos los
    /// servidores de podcasts e imágenes responden igual de bien por https.
    var securedHTTPS: URL {
        guard scheme == "http", var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        else { return self }
        components.scheme = "https"
        return components.url ?? self
    }
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
    private var iChaptersURL: URL?
    private var iBytes: Int64?      // tamaño del audio segun el feed (<enclosure length=...>)
    private var iGuid: String?      // identificador estable del episodio (<guid>)

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
            iTitle = ""; iSummary = ""; iAudio = nil; iDuration = 0; iBytes = nil; iGuid = nil
            iDate = Date(); iImage = nil; iChapters = []; iChaptersURL = nil
        case "image" where !inItem:
            inChannelImage = true
        case "enclosure":
            if let urlString = attributeDict["url"] { iAudio = URL(string: urlString)?.securedHTTPS }
            // El tamaño que anuncia el feed. Se le pasa luego a iOS para que sepa lo que va a
            // descargar (ver `Episode.audioBytes`). Hay feeds que ponen 0 o basura: solo vale si
            // es un número positivo y creíble.
            iBytes = attributeDict["length"].flatMap { Int64($0.trimmed) }.flatMap { $0 > 0 ? $0 : nil }
        case "itunes:image":
            if let href = attributeDict["href"], let url = URL(string: href)?.securedHTTPS {
                if inItem { iImage = url } else { channelImage = url }
            }
        case "psc:chapter":
            if let start = attributeDict["start"], let title = attributeDict["title"] {
                let image = attributeDict["image"].flatMap { URL(string: $0)?.securedHTTPS }
                iChapters.append(Chapter(title: title, start: timecode(start), colorHex: colorHex, imageURL: image))
            }
        case "podcast:chapters":
            if let urlString = attributeDict["url"] { iChaptersURL = URL(string: urlString)?.securedHTTPS }
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
            case "title": iTitle = decodeEntities(value)
            case "guid": iGuid = value.isEmpty ? nil : value
            case "description", "itunes:summary", "content:encoded":
                if iSummary.isEmpty { iSummary = stripHTML(value) }
            case "itunes:duration": iDuration = duration(value)
            case "pubDate": iDate = pubDate(value) ?? iDate
            case "item":
                episodes.append(Episode(
                    title: iTitle, summary: iSummary.trimmed, podcastTitle: channelTitle.trimmed,
                    colorHex: colorHex, artworkURL: iImage ?? channelImage, audioURL: iAudio,
                    duration: iDuration, publishedAt: iDate, chapters: iChapters, chaptersURL: iChaptersURL,
                    audioBytes: iBytes, guid: iGuid
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
                if inChannelImage, channelImage == nil { channelImage = URL(string: value)?.securedHTTPS }
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
    /// Los feeds de podcast usan RFC 822, pero cada proveedor lo escribe a su manera: con día de
    /// la semana o sin él, con zona horaria numérica o con siglas, con segundos o sin ellos, y
    /// alguno cuela ISO-8601. Cada formato que falte aquí no da error: hace que el episodio se
    /// quede con la fecha de "ahora", parezca el más reciente de todos y se cuele el primero en la
    /// cola de descargas por delante de los que sí son nuevos.
    private func pubDate(_ string: String) -> Date? {
        let clean = string.trimmed
        guard !clean.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z",     // el habitual
                       "EEE, dd MMM yyyy HH:mm:ss zzz",   // ...con siglas (GMT, PDT)
                       "EEE, dd MMM yyyy HH:mm Z",        // sin segundos
                       "EEE, dd MMM yyyy HH:mm:ss",       // sin zona horaria
                       "dd MMM yyyy HH:mm:ss Z",          // sin día de la semana
                       "dd MMM yyyy HH:mm:ss zzz",
                       "dd MMM yyyy HH:mm Z",
                       "yyyy-MM-dd'T'HH:mm:ssZ",          // ISO-8601
                       "yyyy-MM-dd'T'HH:mm:ss.SSSZ",      // ...con milésimas
                       "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                       "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: clean) { return date }
        }
        // Último recurso: algunos feeds se dejan el espacio tras la coma ("Tue,16 Sep...").
        if let comma = clean.firstIndex(of: ","), clean.index(after: comma) < clean.endIndex,
           clean[clean.index(after: comma)] != " " {
            var fixed = clean
            fixed.insert(" ", at: clean.index(after: comma))
            return pubDate(fixed)
        }
        return nil
    }

    /// Quita etiquetas HTML básicas de las descripciones.
    private func stripHTML(_ string: String) -> String {
        decodeEntities(string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }

    /// Traduce las entidades HTML más comunes. Se aplica también a los TÍTULOS, que antes se
    /// quedaban con el "&amp;" literal en pantalla.
    private func decodeEntities(_ string: String) -> String {
        string.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")   // el último, o desharía los de arriba
    }
}
