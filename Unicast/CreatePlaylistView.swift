import SwiftUI

/// Crear una lista a mano: nombre + elegir episodios de varios podcasts.
/// Al crearla, si hay episodios de 2+ podcasts, ofrece convertirla en inteligente.
struct CreatePlaylistView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: Set<UUID> = []
    @State private var showSmartPrompt = false

    private var allEpisodes: [Episode] { store.podcasts.flatMap(\.episodes) }
    private var chosen: [Episode] { allEpisodes.filter { selected.contains($0.id) } }
    private var sourceNames: [String] {
        var names: [String] = []
        for episode in chosen where !names.contains(episode.podcastTitle) {
            names.append(episode.podcastTitle)
        }
        return names
    }
    private var canBeSmart: Bool { sourceNames.count >= 2 }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(store.backgroundStyle).ignoresSafeArea()

                List {
                    Section {
                        TextField("", text: $name,
                                  prompt: Text("Nombre de la lista").foregroundStyle(Theme.textMuted))
                            .foregroundStyle(.white)
                    }
                    .listRowBackground(Theme.surface)

                    Section("Añade episodios") {
                        ForEach(allEpisodes) { episode in
                            Button { toggle(episode.id) } label: { episodeRow(episode) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white)
            }
            .navigationTitle("Nueva lista")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Crear") { create() }.disabled(selected.isEmpty)
                }
            }
            .sheet(isPresented: $showSmartPrompt) {
                MakeSmartSheet(sourceNames: sourceNames) { makeSmart in
                    let id = store.createPlaylist(name: name, episodeIDs: orderedSelection())
                    if makeSmart { store.makeSmart(id) }
                    dismiss()
                }
                .presentationDetents([.height(380)])
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["UNICAST_PREVIEW"] == "createSmart" {
                name = "Para el coche"
                selected = Set(store.podcasts.prefix(3).compactMap { $0.episodes.first?.id })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showSmartPrompt = true }
            }
        }
    }

    private func episodeRow(_ episode: Episode) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: episode.colorHex)).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(episode.title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1)
                Text(episode.podcastTitle).font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: selected.contains(episode.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected.contains(episode.id) ? Theme.accent : Theme.textMuted)
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Selección en el orden en que aparecen los episodios (define la prioridad por podcast).
    private func orderedSelection() -> [UUID] {
        allEpisodes.filter { selected.contains($0.id) }.map(\.id)
    }

    private func create() {
        if canBeSmart {
            showSmartPrompt = true
        } else {
            store.createPlaylist(name: name, episodeIDs: orderedSelection())
            dismiss()
        }
    }
}

/// Hoja que ofrece convertir la lista recién creada en inteligente (se actualiza sola).
struct MakeSmartSheet: View {
    let sourceNames: [String]
    let decision: (_ makeSmart: Bool) -> Void

    var body: some View {
        ZStack {
            Theme.background(.purple).ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule().fill(Color(hex: "3A3F4D")).frame(width: 36, height: 5).padding(.top, 10)

                Circle().fill(Color(hex: "251F40")).frame(width: 48, height: 48)
                    .overlay { Image(systemName: "bolt.fill").foregroundStyle(Theme.accentLight).font(.system(size: 24)) }
                    .padding(.top, 18)

                Text("¿Hacerla inteligente?")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .padding(.top, 12)

                Text("Los episodios nuevos de \(formattedNames) entrarán en esta lista solos. Tú sigues decidiendo el orden.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "AEB8CC"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28).padding(.top, 8)

                Spacer()

                Button { decision(true) } label: {
                    Text("Sí, mantenerla al día")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(13)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 22)

                Button { decision(false) } label: {
                    Text("No, dejarla manual")
                        .font(.system(size: 13)).foregroundStyle(Color(hex: "C7D2E8"))
                        .padding(11)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
            }
        }
    }

    private var formattedNames: String {
        switch sourceNames.count {
        case 0: return "tus podcasts"
        case 1: return sourceNames[0]
        case 2: return "\(sourceNames[0]) y \(sourceNames[1])"
        default:
            let head = sourceNames.dropLast().joined(separator: ", ")
            return "\(head) y \(sourceNames.last!)"
        }
    }
}
