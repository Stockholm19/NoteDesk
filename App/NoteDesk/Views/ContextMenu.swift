import SwiftUI

/// Пункт контекстного меню, общий для macOS и iOS.
struct MenuEntry: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([MenuEntry])
        case divider
    }

    let id = UUID()
    var title: String = ""
    var systemImage: String?
    var disabled = false
    var kind: Kind

    static func action(_ title: String, _ systemImage: String? = nil, disabled: Bool = false,
                       _ handler: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, systemImage: systemImage, disabled: disabled, kind: .action(handler))
    }
    static func submenu(_ title: String, _ systemImage: String? = nil, _ items: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, systemImage: systemImage, kind: .submenu(items))
    }
    static var divider: MenuEntry { MenuEntry(kind: .divider) }
}

extension View {
    /// Контекстное меню. На Mac открывается чуть правее и ниже курсора,
    /// чтобы первый пункт не оказывался прямо под указателем.
    func entryContextMenu(_ items: @escaping () -> [MenuEntry]) -> some View {
        #if os(macOS)
        overlay(RightClickMenu(items: items))
        #else
        contextMenu { MenuEntriesView(items: items()) }
        #endif
    }
}

/// SwiftUI-представление пунктов (iOS и вложенные меню).
struct MenuEntriesView: View {
    let items: [MenuEntry]

    var body: some View {
        ForEach(items) { item in
            switch item.kind {
            case .action(let handler):
                Button(action: handler) { label(item) }.disabled(item.disabled)
            case .submenu(let sub):
                Menu { MenuEntriesView(items: sub) } label: { label(item) }
            case .divider:
                Divider()
            }
        }
    }

    @ViewBuilder private func label(_ item: MenuEntry) -> some View {
        if let icon = item.systemImage { Label(item.title, systemImage: icon) } else { Text(item.title) }
    }
}

#if os(macOS)
import AppKit

/// Прозрачная подложка, которая ловит только правый клик (и Ctrl+клик),
/// а обычные клики пропускает к строке списка.
private struct RightClickMenu: NSViewRepresentable {
    let items: () -> [MenuEntry]

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.items = items
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.items = items }

    final class CatcherView: NSView {
        var items: () -> [MenuEntry] = { [] }
        /// Сдвиг меню от курсора, pt
        private let offset = NSSize(width: 14, height: 6)

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            switch e.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where e.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) { show(event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show(event) } else { super.mouseDown(with: event) }
        }

        private func show(_ event: NSEvent) {
            let entries = items()
            guard !entries.isEmpty else { return }
            let p = convert(event.locationInWindow, from: nil)
            let at = NSPoint(x: p.x + offset.width, y: isFlipped ? p.y + offset.height : p.y - offset.height)
            build(entries).popUp(positioning: nil, at: at, in: self)
        }

        /// Пункт меню хранит свой обработчик в representedObject, цель — сама подложка.
        private final class Handler {
            let run: () -> Void
            init(_ run: @escaping () -> Void) { self.run = run }
        }

        @objc private func fire(_ sender: NSMenuItem) { (sender.representedObject as? Handler)?.run() }

        private func build(_ entries: [MenuEntry]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for e in entries {
                switch e.kind {
                case .divider:
                    menu.addItem(.separator())
                case .action(let handler):
                    let item = NSMenuItem(title: e.title, action: #selector(fire(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = Handler(handler)
                    item.isEnabled = !e.disabled
                    item.image = e.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                    menu.addItem(item)
                case .submenu(let sub):
                    let item = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
                    item.image = e.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                    item.submenu = build(sub)
                    menu.addItem(item)
                }
            }
            return menu
        }
    }
}
#endif
