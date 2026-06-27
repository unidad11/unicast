# Unicast 🎧

App de podcasts para iPhone, **nativa (SwiftUI)**, inspirada en Overcast pero con vista por
tarjetas y estética tipo Brink. Construida **sin dependencias externas** (solo frameworks de Apple).

## Qué hace (ya funcionando en el simulador)
- **Buscar** podcasts en el directorio de iTunes y **suscribirse** (descarga el feed real).
- **Biblioteca** con 3 vistas: cuadrícula de portadas, **mazos** (cartas estilo Brink) y lista.
- **Dentro de un podcast**: pestañas Descargados / Todos, resumen del autor, deslizar para borrar.
- **Reproductor**: portada, barra arrastrable, **±30 s**, notas y capítulos. Controles en la
  **pantalla de bloqueo, AirPods y Dynamic Island** (Now Playing). Audio en **segundo plano**.
- **Descargas** a disco, **refresco** de feeds (desliza hacia abajo) con **auto-descarga** de los nuevos.
- **Recuerda** el último episodio y la **posición exacta**. **Autoborrado** al terminar / faltando <40 s.
- **Listas** de reproducción manuales y la **inteligente** que copia una manual (se llena sola).
- **Ajustes** por podcast y generales, con **selector de fondo** (degradado configurable).
- **Notificaciones** al descargar. Todo se **guarda** entre sesiones.

## Cómo abrirla y ejecutarla
- Abrir en Xcode: `Unicast.xcodeproj` (Xcode 26+, iOS 17+).
- Ejecutar en el simulador desde Xcode (botón ▶), o por terminal:
  ```sh
  cd "podcast-ios"
  xcodebuild -project Unicast.xcodeproj -target Unicast -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO
  xcrun simctl install booted build/Debug-iphonesimulator/Unicast.app
  xcrun simctl launch booted com.jbs.Unicast
  ```
- En **tu iPhone**: con la cuenta Apple gratuita, la firma caduca a los 7 días (igual que tu
  Conversor); se renueva reinstalando desde Xcode.

## Estructura del código (`Unicast/`)
- **Estado/datos:** `Models`, `Store` (@Observable), `Persistence`, `SampleData`.
- **Motor:** `RSSParser`, `PodcastService` (iTunes + feeds), `DownloadManager`, `AudioPlayer`, `Notifications`.
- **Interfaz:** `LibraryView`, `PodcastDetailView`, `PlayerView`, `PlaylistsView` / `PlaylistDetailView`,
  `CreatePlaylistView`, `SearchView` / `AddPodcastView`, `SettingsView` / `BackgroundPickerView`,
  `Components`, `Theme`.

## Pendiente (a decidir juntos)
- Pestaña **Descubrir** (recomendador de podcasts similares): necesita un servicio externo,
  probablemente de pago (Listen Notes / Podchaser). Pendiente de elegir.
- **Isla a medida** (Live Activity) más elaborada que el Now Playing del sistema: opcional.
- Pulido visual y pruebas en iPhone físico.

## Nota
La app arranca con unos podcasts de ejemplo para que se vea bonita al abrir; en cuanto buscas
y te suscribes a podcasts reales, manda el contenido real (y se guarda).
