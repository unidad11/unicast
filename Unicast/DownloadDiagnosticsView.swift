import SwiftUI
import UIKit

/// Ajustes → Descargas → Diagnóstico. Responde con datos, no con sensaciones, a la única pregunta
/// que importa: "¿por qué no se me descargan solos los episodios?".
///
/// Enseña en orden las cuatro cosas que pueden fallar: si iOS tiene permiso para despertar la app,
/// si la app INSTALADA declara de verdad los modos de segundo plano (aquí se habría cantado el bug
/// que lo rompía todo: el bundle solo declaraba "audio"), si el sistema está aceptando las citas
/// que se le piden, y qué queda pendiente de bajar. Debajo, el historial real de despertares.
struct DownloadDiagnosticsView: View {
    @Environment(AppStore.self) private var store
    @Environment(DownloadManager.self) private var downloads

    @State private var refreshStatus = UIApplication.shared.backgroundRefreshStatus
    @State private var pending: [PendingDownload] = []
    @State private var wakes: [WakeEvent] = []
    @State private var attempts: [BackgroundScheduling.Attempt] = []
    @State private var justAsked = false

    var body: some View {
        ZStack {
            Theme.background(store.backgroundStyle).ignoresSafeArea()

            List {
                permissionSection
                bundleSection
                scheduleSection
                pendingSection
                wakeSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
        }
        .navigationTitle("Diagnóstico")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    /// Todo se lee de golpe al entrar: son cuatro ficheros pequeños y así la foto es coherente.
    private func reload() {
        refreshStatus = UIApplication.shared.backgroundRefreshStatus
        pending = store.pendingDownloads()
        wakes = Array(WakeLog.load().suffix(20).reversed())   // el más reciente arriba
        attempts = BackgroundScheduling.lastAttempts
    }

    // MARK: - ¿Nos despierta iOS?

    private var permissionSection: some View {
        Section {
            row("Actualización en segundo plano", value: refreshLabel, ok: refreshStatus == .available)
            if refreshStatus != .available {
                hint("Sin esto iOS no despierta nunca a Unicast. Se activa en los Ajustes de iOS → "
                     + "General → Actualización en segundo plano. Ojo: el modo de bajo consumo la "
                     + "desactiva mientras está puesto.")
            }
        } header: {
            Text("¿Te despierta iOS?")
        }
        .listRowBackground(Theme.surface)
    }

    private var refreshLabel: String {
        switch refreshStatus {
        case .available: return "Permitida"
        case .denied: return "Desactivada"
        case .restricted: return "Bloqueada por el dispositivo"
        @unknown default: return "Desconocida"
        }
    }

    // MARK: - ¿Lo declara la app instalada?

    private var bundleSection: some View {
        let modes = BackgroundScheduling.declaredBackgroundModes
        let ok = BackgroundScheduling.bundleIsCorrectlyDeclared
        return Section {
            row("Modos declarados", value: modes.isEmpty ? "ninguno" : modes.joined(separator: ", "), ok: ok)
            row("Tareas permitidas", value: "\(BackgroundScheduling.permittedIdentifiers.count) de 2",
                ok: BackgroundScheduling.permittedIdentifiers.count >= 2)
            if !ok {
                hint("Faltan «fetch» y/o «processing». Mientras falten, iOS rechaza TODAS las "
                     + "peticiones de refresco en segundo plano y no hay descargas nocturnas. "
                     + "No se arregla desde el móvil: hay que instalar la app corregida.")
            }
        } header: {
            Text("Lo que declara la app instalada")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - ¿Acepta iOS las citas?

    private var scheduleSection: some View {
        Section {
            if attempts.isEmpty {
                Text("Todavía no se ha pedido ninguna cita en esta instalación.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            ForEach(attempts) { attempt in
                VStack(alignment: .leading, spacing: 3) {
                    row(shortName(attempt.identifier),
                        value: attempt.succeeded ? "Aceptada" : "Rechazada",
                        ok: attempt.succeeded)
                    Text(timestamp(attempt.date))
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    if let failure = attempt.failure {
                        Text(failure)
                            .font(.system(size: 11)).foregroundStyle(Color(hex: "D23A39"))
                    }
                }
            }
            Button {
                BackgroundScheduling.scheduleAll()
                justAsked = true
                attempts = BackgroundScheduling.lastAttempts
            } label: {
                Label(justAsked ? "Pedidas de nuevo" : "Volver a pedir las citas",
                      systemImage: "calendar.badge.clock")
            }
        } header: {
            Text("Último intento de cada cita")
        } footer: {
            Text("iOS nunca garantiza la hora: decide él cuándo concede cada cita, o si la concede.")
        }
        .listRowBackground(Theme.surface)
    }

    private func shortName(_ identifier: String) -> String {
        identifier == BackgroundScheduling.refreshIdentifier ? "Refresco corto" : "Procesamiento largo"
    }

    // MARK: - Qué falta por bajar

    private var pendingSection: some View {
        Section {
            row("Pendientes de descargar", value: "\(pending.count)", ok: pending.isEmpty)
            if !downloads.downloading.isEmpty {
                row("Bajándose ahora mismo", value: "\(downloads.downloading.count)", ok: true)
            }
            ForEach(pending.prefix(12)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.episode.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Text("\(item.episode.podcastTitle) · \(relativeDay(item.episode.publishedAt))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            if pending.count > 12 {
                Text("y \(pending.count - 12) más…")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            if !pending.isEmpty {
                Button {
                    store.downloadPending(using: downloads)
                    pending = store.pendingDownloads()
                } label: {
                    Label("Descargar lo que falta", systemImage: "arrow.down.circle")
                }
            }
        } header: {
            Text("Pendiente")
        } footer: {
            Text("Al pedirlo tú no se aplica «Descargar solo con WiFi»: se baja con la red que haya.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - Historial de despertares

    private var wakeSection: some View {
        Section {
            if wakes.isEmpty {
                Text("Todavía no hay ningún despertar registrado.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            // Por índice: `WakeEvent` no tiene id propio y dos despertares podrían coincidir.
            ForEach(wakes.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(triggerLabel(wakes[index].trigger))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        Text(timestamp(wakes[index].date))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(summaryLine(wakes[index]))
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        } header: {
            Text("Últimos despertares")
        } footer: {
            Text("«Segundo plano» son los que ha concedido iOS sin abrir tú la app. Si no aparece "
                 + "ninguno en días, el problema está arriba y no en las descargas.")
        }
        .listRowBackground(Theme.surface)
    }

    private func triggerLabel(_ trigger: WakeEvent.Trigger) -> String {
        switch trigger {
        case .appRefresh: "Segundo plano (corto)"
        case .processing: "Segundo plano (largo)"
        case .foreground: "Al abrir la app"
        case .shortcut: "Desde Atajos"
        }
    }

    private func summaryLine(_ wake: WakeEvent) -> String {
        var parts = ["\(wake.podcastsChanged) con novedades"]
        if wake.podcastsFailed > 0 { parts.append("\(wake.podcastsFailed) fallaron") }
        parts.append("\(Int(wake.durationSeconds)) s")
        return parts.joined(separator: " · ")
    }

    // MARK: - Piezas comunes

    /// Aquí sí hace falta la HORA: lo que se está diagnosticando es a qué horas despierta iOS a la
    /// app, y `relativeDay` se queda en "Hoy" / "Ayer".
    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "'hoy' HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private func row(_ title: String, value: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(ok ? Theme.downloaded : Color(hex: "D23A39"))
                .multilineTextAlignment(.trailing)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
    }
}
