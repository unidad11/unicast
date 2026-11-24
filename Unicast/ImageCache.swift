import SwiftUI
import CryptoKit
import ImageIO

/// Caché de imágenes (carátulas) en memoria + disco, para que se vean al instante y sin internet
/// entre aperturas de la app.
///
/// - En disco se guarda el ORIGINAL de cada URL (nombre = hash estable de la URL).
/// - En memoria se guarda una versión YA REDUCIDA y ya decodificada (`maxPixel`): las carátulas se
///   dibujan como mucho a ~100 pt, así que no hace falta preparar imágenes de 2000 px. Reducir y
///   decodificar se hace FUERA del hilo principal; antes se hacía en él, una por una, al abrir.
/// - La carpeta de disco está en Application Support (iOS no la vacía cuando falta espacio, a
///   diferencia de Caches) y fuera de la copia de iCloud. Si un fichero se guardó antes en
///   Caches/Covers, se sigue leyendo de ahí.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// Lado máximo, en píxeles, de la versión reducida (la carátula más grande ronda los 104 pt a 3x).
    static let maxPixel = 384

    private let memory = NSCache<NSURL, UIImage>()
    private let folder: URL
    private let oldFolder: URL
    private let lock = NSLock()
    private var enCurso: [URL: Task<UIImage?, Never>] = [:]
    /// URLs de las que ya se comprobó que NO hay miniatura en disco (evita repetir la comprobación en cada dibujado).
    private var sinMiniatura: Set<URL> = []

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var carpeta = support.appendingPathComponent("Covers", isDirectory: true)
        try? fm.createDirectory(at: carpeta, withIntermediateDirectories: true)
        var valores = URLResourceValues()
        valores.isExcludedFromBackup = true
        try? carpeta.setResourceValues(valores)
        folder = carpeta
        oldFolder = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
        memory.countLimit = 300
    }

    // MARK: - Reducción (pura, sin tocar la caché)

    /// Devuelve la imagen reducida a `maxPixel` de lado máximo y YA decodificada, o nil si los datos no son una imagen.
    static func reducida(from data: Data, maxPixel: Int = ImageCache.maxPixel) -> UIImage? {
        let origen = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        guard let origen else { return nil }
        let opciones: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,   // decodifica ahora, no al dibujar
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(origen, 0, opciones as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Acceso

    private func fichero(para url: URL, en carpeta: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return carpeta.appendingPathComponent(hash)
    }

    private func miniatura(para url: URL) -> URL {
        fichero(para: url, en: folder).appendingPathExtension("t\(Self.maxPixel)")
    }

    /// Al instante y sin esperar: primero la memoria; si no, la MINIATURA ya reducida que hay en disco
    /// (unos pocos KB, se lee y decodifica en milisegundos). Así, aunque la app se acabe de abrir y la
    /// memoria esté vacía, la carátula sale en el primer dibujado, sin pasar por el cuadro de color.
    func cachedImage(for url: URL) -> UIImage? {
        if let enMemoria = memory.object(forKey: url as NSURL) { return enMemoria }
        lock.lock(); let descartada = self.sinMiniatura.contains(url); lock.unlock()
        if descartada { return nil }
        if let datos = try? Data(contentsOf: miniatura(para: url)), let imagen = Self.reducida(from: datos) {
            memory.setObject(imagen, forKey: url as NSURL)
            return imagen
        }
        lock.lock(); self.sinMiniatura.insert(url); lock.unlock()
        return nil
    }

    /// Guarda la miniatura reducida para que la próxima vez salga al instante.
    private func guardarMiniatura(_ imagen: UIImage, para url: URL) {
        guard let datos = imagen.jpegData(compressionQuality: 0.85) else { return }
        try? datos.write(to: miniatura(para: url))
        lock.lock(); sinMiniatura.remove(url); lock.unlock()
    }

    /// Da la imagen reducida para esa URL: de memoria, de disco, o la descarga y la guarda para la próxima vez.
    func image(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        let resultado = await tareaDeCarga(para: url).value
        terminarCarga(de: url)
        return resultado
    }

    /// Una sola carga por URL a la vez: si ya hay una en marcha, se espera a esa misma.
    private func tareaDeCarga(para url: URL) -> Task<UIImage?, Never> {
        lock.lock(); defer { lock.unlock() }
        if let existente = enCurso[url] { return existente }
        let tarea = Task.detached(priority: .userInitiated) { [self] in await cargar(url) }
        enCurso[url] = tarea
        return tarea
    }

    private func terminarCarga(de url: URL) {
        lock.lock(); enCurso[url] = nil; lock.unlock()
    }

    private func cargar(_ url: URL) async -> UIImage? {
        let nuevo = fichero(para: url, en: folder)
        let viejo = fichero(para: url, en: oldFolder)
        for ruta in [nuevo, viejo] {
            if let data = try? Data(contentsOf: ruta), let imagen = Self.reducida(from: data) {
                memory.setObject(imagen, forKey: url as NSURL)
                // Si estaba en la carpeta antigua (Caches), se pasa a la nueva para que iOS no la vacíe.
                if ruta == viejo, !FileManager.default.fileExists(atPath: nuevo.path) { try? data.write(to: nuevo) }
                guardarMiniatura(imagen, para: url)
                return imagen
            }
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let imagen = Self.reducida(from: data) else { return nil }
        memory.setObject(imagen, forKey: url as NSURL)
        try? data.write(to: nuevo)
        guardarMiniatura(imagen, para: url)
        return imagen
    }

    /// Carga por adelantado (en segundo plano) las carátulas dadas, de pocas en pocas, para que al
    /// abrir las pantallas ya estén en memoria.
    func preload(_ urls: [URL]) async {
        var pendientes = Array(Set(urls)).filter { cachedImage(for: $0) == nil }
        while !pendientes.isEmpty {
            let lote = pendientes.prefix(4)
            pendientes.removeFirst(lote.count)
            await withTaskGroup(of: Void.self) { grupo in
                for url in lote { grupo.addTask { _ = await ImageCache.shared.image(for: url) } }
            }
        }
    }
}

/// Como `AsyncImage`, pero pasando por `ImageCache`: una vez descargada, la carátula
/// queda fija en disco y se ve al momento aunque no haya conexión. Si ya está en memoria,
/// sale en el PRIMER dibujado, sin pasar por el marcador de posición.
struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    init(url: URL,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        _uiImage = State(initialValue: ImageCache.shared.cachedImage(for: url))
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if let enMemoria = ImageCache.shared.cachedImage(for: url) {
                uiImage = enMemoria
                return
            }
            uiImage = await ImageCache.shared.image(for: url)
        }
    }
}
