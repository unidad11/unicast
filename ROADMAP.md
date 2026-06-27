# App de Podcasts — Hoja de ruta

App **nativa de iPhone** (SwiftUI), inspirada en Overcast pero con vista por tarjetas
e ideas propias. Decisión tomada el 26/06/2026.

## ✅ ESTADO 27/06/2026 — CONSTRUIDA Y FUNCIONAL
App creada en `Unicast.xcodeproj` (~25 archivos Swift); compila y corre en el simulador. Ver
`README.md`. **Implementado:** búsqueda iTunes real + suscripción a feeds, 3 vistas de biblioteca
(cuadrícula/mazos/lista), dentro del podcast (Descargados/Todos, swipe-borrar), reproductor
(±30 s, barra, notas/capítulos, pantalla de bloqueo/AirPods/Dynamic Island, segundo plano),
descargas, refresco + auto-descarga, posición exacta, autoborrado, listas (manual + inteligente),
ajustes por podcast y generales, fondo configurable, notificaciones y persistencia. **Pendiente:**
Descubrir/recomendador (servicio externo, consultar), isla a medida (opcional), pulido. Los puntos
de abajo quedan prácticamente todos cubiertos.

- **Cuenta Apple:** gratuita → la firma caduca cada 7 días (se renueva desde el Mac,
  igual que el Conversor de Divisas).
- **Fuera por decisión propia (punto 10):** NO quitar silencios, NO cambiar velocidad.

---

## Fase 1 — Motor (la fontanería que no se ve)
- [ ] Buscar podcasts por nombre en cualquier sitio + añadir por URL  *(punto 8)*
- [ ] Importar podcasts desde archivo OPML  *(punto 25)*
- [ ] Soportar podcasts privados (URL con acceso)  *(punto 26)*
- [ ] Leer cada podcast: episodios con capítulos, imágenes, duración y descripción del autor  *(puntos 9, 14)*
- [ ] Actualización constante en segundo plano  *(punto 23)*

## Fase 2 — Interfaz (lo que ves y tocas)
- [ ] Vista por **tarjetas** de cada podcast  *(punto 1)*
- [ ] Cambiar entre vista **lista** y **cuadrícula de pósters**  *(punto 20)*
- [ ] Ordenar los podcasts por más reciente / más antiguo  *(punto 6)*
- [ ] Dentro de un podcast: imagen, duración, descripción y lista de capítulos  *(punto 14)*
- [ ] Seleccionar varios capítulos (o todos) y borrarlos  *(punto 16)*
- [ ] Deslizar un capítulo a la izquierda para borrarlo (con animación)  *(punto 17)*
- [ ] Dentro del podcast, 2 pestañas estilo Overcast (sin "Escuchados"): **Descargados** (1ª) y **Todos** (2ª)  *(punto 18)*
  - "Todos" = el feed completo MENOS los que están descargados ahora mismo
  - El **mini-reproductor** solo se ve en Descargados; en Todos cada episodio tiene botón de **descargar**
  - Al escuchar+borrar un descargado (punto 19), vuelve al feed de "Todos"
- [ ] **Ajustes por podcast** (desde el "···" de la pantalla del podcast): nº de descargas automáticas, orden de la lista y modo de reproducción continua — **distinto para cada podcast**, no solo global  *(puntos 5, 6, 7a por podcast)*
- [ ] En el reproductor, **deslizar la portada** muestra las **notas del autor** y los **capítulos con sus imágenes**, estilo Overcast  *(puntos 9, 14)*
- [ ] Diseño simple y distinto a Overcast  *(punto 21)*
- [ ] Vista **Mazos**: CUADRÍCULA de celdas grandes (2 por fila) estilo Brink; cuando un podcast tiene varios episodios, asoman cartas por detrás del cuadro. Nombres con tipografía display con carácter (cómic o rock, a elegir). SIN categorías
- [ ] **Cuadrícula = pantalla de inicio** por defecto; pósters pequeños y densos, sin texto ni badges
- [ ] Pantalla de **Ajustes** — (a) activar/desactivar el contador de nuevos sobre cada póster (OFF de fábrica); (b) **fondo con degradado configurable**: elegir colores (p.ej. negro-azul o negro-amarillo suave)

## Fase 3 — Reproducción
- [ ] Reproductor con barra de progreso para adelantar/retrasar arrastrando  *(punto 13)*
- [ ] Capítulos e imágenes del autor durante la reproducción  *(punto 9)*
- [ ] Botones **±30 segundos** que el iPhone reconozca (bloqueo, AirPods)  *(punto 15)*
- [ ] **Isla del iPhone** (Live Activity), simple: icono del podcast, barra de progreso y botones −30s / +30s / play-pausa. Nada más  *(punto 2)*
- [ ] Recordar el último podcast y el momento exacto al abrir la app  *(punto 11)*
- [ ] Al saltar de un podcast a otro, guardar dónde se quedó cada uno  *(punto 12)*
- [ ] Reproducción continua dentro de un podcast, eligiendo hacia recientes o antiguos  *(punto 5)*

## Fase 4 — Listas y automatización
- [ ] Enviar un episodio a una lista de reproducción  *(punto 3a)*
- [ ] Ordenar a mano las listas: 1º, 2º, 3º…  *(punto 4)*
- [ ] Renombrar las listas
- [ ] **Lista inteligente (solo "por fuentes"):** al crear/editar una lista MANUAL con episodios, la app pregunta si quieres convertirla en inteligente; si aceptas, los episodios nuevos de ESOS mismos podcasts entran solos. La variante "por reglas/criterios" queda DESCARTADA (el usuario no la usa)  *(punto 3b)*
  - **Orden POR PODCAST:** el orden que el usuario fija a mano en la lista manual define la prioridad de cada podcast. En la inteligente, cada episodio nuevo se coloca según la posición de su podcast (no por fecha)  *(puntos 4 y 5 aplicados a la lista)*
- [ ] Elegir cuántos episodios se bajan solos: todos / 5-10 / un número mío  *(punto 7a)*
- [ ] Descarga automática de episodios  *(punto 7b)*
- [ ] Autoborrado al terminar, o si faltan menos de 40 segundos  *(punto 19)*
- [ ] Notificación cada vez que se baja un episodio  *(punto 22)*

## Fase 5 — Extras
- [ ] Pestaña que recomienda podcasts similares a los que escucho  *(punto 24 — requiere servicio externo, a investigar)*
- [ ] Exportar mis podcasts a OPML  *(punto 25)*
- [ ] Ideas tomadas de otras apps: cola arrastrable (Castro), filtros por estado (Pocket Casts), recorte de 30s (Snipd)

---

### Notas de las partes con miga
- **Lista inteligente (3b):** UN solo tipo, "por fuentes". Nace de una lista manual: el
  usuario crea una lista añadiendo episodios y la app le ofrece convertirla en inteligente;
  si acepta, los episodios nuevos de ESOS podcasts entran solos. La variante "por reglas"
  está DESCARTADA (jun 2026): el usuario no la usa ni tiene claros los criterios.
- **Escuchados+borrados (18) y autoborrado (19):** compatibles. Se borra el audio para
  no ocupar espacio, pero se guarda el registro de "ya escuchado".
- **Recomendador (24):** depende de un servicio externo (Listen Notes, Podchaser…),
  algunos de pago. Se decide en la Fase 5.
