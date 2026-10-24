import SwiftUI

/// Теги заметки под заголовком: «чипы» с крестиком и кнопка «Тег».
struct NoteTagsRow: View {
    @Environment(SyncEngine.self) private var engine
    let note: LocalNote
    @State private var picking = false

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(note.tags, id: \.self) { tag in
                TagChip(title: tag) {
                    engine.setTags(note, note.tags.filter { $0 != tag })
                }
            }
            Button {
                picking = true
            } label: {
                Label(note.tags.isEmpty ? "Добавить тег" : "Тег", systemImage: "plus")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(note.isEncrypted)
        }
        .sheet(isPresented: $picking) {
            NavigationStack { TagPicker(note: note) }
        }
    }
}

/// Тег: «родитель/ребёнок» из Note Station показываем как «родитель › ребёнок».
struct TagChip: View {
    let title: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag").imageScale(.small)
            Text(TagChip.display(title)).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Убрать тег")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.tint.opacity(0.12)))
        .foregroundStyle(.tint)
    }

    static func display(_ tag: String) -> String {
        tag.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " › ")
    }
}

/// Выбор тегов: поиск по существующим и создание нового. «/» в названии — вложенный тег.
struct TagPicker: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let note: LocalNote
    @State private var query = ""

    var body: some View {
        List {
            if canCreate {
                Section {
                    Button {
                        engine.setTags(note, note.tags + [trimmed])
                        query = ""
                    } label: {
                        Label("Создать тег «\(trimmed)»", systemImage: "plus.circle")
                    }
                }
            }
            Section(query.isEmpty ? "Все теги" : "Найдено") {
                ForEach(matches, id: \.self) { tag in
                    Button {
                        toggle(tag)
                    } label: {
                        HStack {
                            Text(TagChip.display(tag))
                                .foregroundStyle(.primary)
                            Spacer()
                            if note.tags.contains(tag) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: "Найти или создать тег")
        .onSubmit(of: .search) { if canCreate { engine.setTags(note, note.tags + [trimmed]); query = "" } }
        .navigationTitle("Теги")
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Существующие теги плюс уже выбранные (новые, ещё не синхронизированные)
    private var allTags: [String] {
        Array(Set(engine.stats.tags + note.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var matches: [String] {
        guard !trimmed.isEmpty else { return allTags }
        return allTags.filter { $0.localizedStandardContains(trimmed) }
    }

    private var canCreate: Bool {
        !trimmed.isEmpty && !allTags.contains { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    private func toggle(_ tag: String) {
        if note.tags.contains(tag) { engine.setTags(note, note.tags.filter { $0 != tag }) }
        else { engine.setTags(note, note.tags + [tag]) }
    }
}

/// Строки «чипов» с переносом.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
