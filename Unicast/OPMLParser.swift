import Foundation

/// Extrae las URLs de los feeds de un archivo OPML (para importar suscripciones de otra app).
final class OPMLParser: NSObject, XMLParserDelegate {
    private var feeds: [URL] = []

    func parse(data: Data) -> [URL] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return feeds
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "outline" else { return }
        // En OPML, el feed va en el atributo xmlUrl (algunos exportan xmlURL).
        if let value = attributeDict["xmlUrl"] ?? attributeDict["xmlURL"],
           let url = URL(string: value) {
            feeds.append(url)
        }
    }
}
