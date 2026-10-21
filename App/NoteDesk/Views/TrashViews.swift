import SwiftUI
import NoteStationKit

/// Корзина Note Station. Локально не хранится: список берётся с сервера при открытии.
struct TrashListView: View {
    @Environment(SyncEngine.self) private var engine
    @Binding var selection: String?
    @Binding var version: Int
    @State private var notes: [NSNote] = []
    @State private var loading = true
    @State private var error: String?
    @State private var confirmEmpty = false
    @State private var deleting: [String] = []

    var body: some View {
        List(selection: $selection) {
            ForEach(notes) { n in
                TrashRow(note: n)
                    .tag(n.id)
                    .contextMenu {
                        Button("Восстановить", systemImage: "arrow.uturn.backward") { restore([n.id]) }
                        Button("Удалить навсегда…", systemImage: "trash", role: .destructive) { deleting = [n.id] }
                    }
            }
        }
        .overlay {
            if loading && notes.isEmpty {
                ProgressView("Загружаю корзину…")
            } else if let error {
                ContentUnavailableView("Корзина недоступна", systemImage: "exclamationmark.icloud", description: Text(error))
            } else if notes.isEmpty {
                ContentUnavailableView("Корзина пуста", systemImage: "trash")
            }
        }
        .navigationTitle("Корзина")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Очистить корзину", systemImage: "trash.slash") { confirmEmpty = true }
                    .disabled(notes.isEmpty)
                    .help("Удалить навсегда все заметки из корзины")
            }
        }
        .task(id: version) { await load() }
        .confirmationDialog("Удалить навсегда все заметки из корзины (\(notes.count))? Вернуть их будет нельзя.",
                            isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Очистить корзину", role: .destructive) { remove(notes.map(\.id)) }
        }
        .confirmationDialog("Удалить заметку навсегда? Вернуть её будет нельзя.",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                            titleVisibility: .visible) {
            Button("Удалить навсегда", role: .destructive) { remove(deleting); deleting = [] }
        }
    }

    private func load() async {
        loading = true
        do {
            notes = try await engine.trashedNotes()
            error = nil
            if let s = selection, !notes.contains(where: { $0.id == s }) { selection = nil }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func restore(_ ids: [String]) {
        Task {
            do { try await engine.restore(ids) } catch { self.error = error.localizedDescription }
            version += 1
        }
    }

    private func remove(_ ids: [String]) {
        Task {
            do { try await engine.deleteForever(ids) } catch { self.error = error.localizedDescription }
            version += 1
        }
    }
}

private struct TrashRow: View {
    let note: NSNote

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DateBadge(date: note.mtime ?? .now)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title.isEmpty ? "Без названия" : note.title).font(.headline).lineLimit(1)
                if !note.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note.brief).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Просмотр заметки из корзины — только чтение.
struct TrashDetailView: View {
    @Environment(SyncEngine.self) private var engine
    let noteID: String
    @Binding var version: Int
    @Binding var selection: String?
    @State private var note: NSNote?
    @State private var images: [String: String] = [:]
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var controller = EditorController()
    @State private var key = UUID()

    var body: some View {
        Group {
            if let note {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.title.isEmpty ? "Без названия" : note.title).font(.title2.bold())
                        Label("В корзине · изменена \(note.mtime?.formatted(date: .abbreviated, time: .shortened) ?? "—")",
                              systemImage: "trash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    Divider()
                    if note.encrypt {
                        ContentUnavailableView("Зашифрованная заметка", systemImage: "lock")
                    } else {
                        HTMLEditor(documentKey: key, html: note.content ?? "", images: images, editable: false,
                                   baseURL: engine.account?.serverURL, controller: controller) { _ in }
                    }
                }
            } else if let error {
                ContentUnavailableView("Не удалось открыть", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("Загружаю…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Восстановить", systemImage: "arrow.uturn.backward") {
                    Task {
                        do { try await engine.restore([noteID]); selection = nil } catch { self.error = error.localizedDescription }
                        version += 1
                    }
                }
                Button("Удалить навсегда", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("Удалить заметку навсегда? Вернуть её будет нельзя.", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Удалить навсегда", role: .destructive) {
                Task {
                    do { try await engine.deleteForever([noteID]); selection = nil } catch { self.error = error.localizedDescription }
                    version += 1
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let n = try await engine.remoteNote(id: noteID)
            var map: [String: String] = [:]
            for a in n.attachments {
                if let ref = a.ref, let u = await engine.attachmentURL(noteID: noteID, fileID: a.id) { map[ref] = u.absoluteString }
            }
            images = map
            note = n
        } catch {
            self.error = error.localizedDescription
        }
    }
}
