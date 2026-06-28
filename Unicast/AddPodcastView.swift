import SwiftUI
import UniformTypeIdentifiers

/// Añadir un podcast a mano: por la URL de su feed (con soporte de podcasts privados)
/// o importando un archivo OPML.
struct AddPodcastView: View {
    @Environment(AppStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var isPrivate = false
    @State private var user = ""
    @State private var password = ""
    @State private var isAdding = false
    @State private var errorText: String?
    @State private var showImporter = false
    @State private var importing = false
    @State private var importDone = 0
    @State private var importTotal = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background().ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        fieldLabel("Dirección del feed (URL)")
                        field($url, placeholder: "https://ejemplo.com/feed.xml")

                        Toggle(isOn: $isPrivate) {
                            Label("Es un podcast privado", systemImage: "lock").foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.accent)

                        if isPrivate {
                            field($user, placeholder: "usuario@correo.com")
                            secureField($password, placeholder: "Contraseña")
                        }

                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: "E24B4A"))
                        }

                        Button { addByURL() } label: {
                            HStack(spacing: 8) {
                                if isAdding { ProgressView().tint(.white) }
                                Text(isAdding ? "Añadiendo…" : "Añadir podcast")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(13)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdding || url.trimmed.isEmpty)
                        .padding(.top, 4)

                        HStack {
                            line; Text("o").font(.system(size: 11)).foregroundStyle(Theme.textSecondary); line
                        }
                        .padding(.vertical, 4)

                        Button { showImporter = true } label: {
                            HStack(spacing: 10) {
                                if importing { ProgressView().tint(Theme.accent) }
                                else { Image(systemName: "square.and.arrow.down").foregroundStyle(Theme.accent) }
                                Text(importing ? "Importando \(importDone) de \(importTotal)…" : "Importar desde archivo OPML")
                                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.textMuted)
                            }
                            .padding(13)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(importing)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Añadir podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: opmlTypes,
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { importOPML(from: url) }
            }
        }
    }

    private var opmlTypes: [UTType] {
        var types: [UTType] = [.xml, .text]
        if let opml = UTType(filenameExtension: "opml") { types.insert(opml, at: 0) }
        return types
    }

    /// Lee el OPML elegido y se suscribe a todos sus podcasts.
    private func importOPML(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorText = "No se pudo leer el archivo."; return
        }
        let feeds = OPMLParser().parse(data: data)
        guard !feeds.isEmpty else {
            errorText = "El archivo no parece un OPML con podcasts."; return
        }
        errorText = nil
        importing = true
        importTotal = feeds.count
        importDone = 0
        Task {
            for feed in feeds {
                if let podcast = await PodcastService.fetchPodcast(
                    feedURL: feed, colorHex: colorHexFor(feed.host ?? "feed")
                ) {
                    store.subscribe(podcast, downloads: downloads)
                }
                importDone += 1
            }
            importing = false
            dismiss()
        }
    }

    /// Descarga el feed de la URL y, si es un podcast válido, lo añade a la biblioteca.
    private func addByURL() {
        var text = url.trimmed
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let feedURL = URL(string: text), text.contains(".") else {
            errorText = "Esa dirección no parece válida."
            return
        }
        errorText = nil
        isAdding = true
        Task {
            let podcast = await PodcastService.fetchPodcast(
                feedURL: feedURL,
                colorHex: colorHexFor(feedURL.host ?? text),
                user: isPrivate ? user : nil,
                password: isPrivate ? password : nil
            )
            isAdding = false
            if let podcast {
                store.subscribe(podcast, downloads: downloads)
                dismiss()
            } else {
                errorText = "No se pudo leer un podcast en esa URL. Revísala."
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
    }

    private func field(_ text: Binding<String>, placeholder: String) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Theme.textMuted))
            .foregroundStyle(Theme.textPrimary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.surfaceBorder))
    }

    private func secureField(_ text: Binding<String>, placeholder: String) -> some View {
        SecureField("", text: text, prompt: Text(placeholder).foregroundStyle(Theme.textMuted))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.surfaceBorder))
    }

    private var line: some View { Rectangle().fill(Theme.surfaceBorder).frame(height: 1) }
}
