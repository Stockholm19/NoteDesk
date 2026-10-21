import SwiftUI
import WebKit
import os

let editorLog = Logger(subsystem: "ru.klotze.NoteDesk", category: "editor")

/// Команды редактора из SwiftUI-тулбара.
@Observable
final class EditorController {
    fileprivate weak var webView: WKWebView?
    var state: [String: Bool] = [:]

    func exec(_ command: String, _ value: String? = nil) {
        let v = value.map { "'\($0)'" } ?? "null"
        webView?.evaluateJavaScript("nd.exec('\(command)', \(v))")
    }

    /// Отмена и повтор — своя история редактора (см. EditorPage).
    func undo() { webView?.evaluateJavaScript("nd.undo()") }
    func redo() { webView?.evaluateJavaScript("nd.redo()") }

    /// Фокус ввода сейчас в редакторе (а не, например, в поле заголовка).
    var hasFocus: Bool {
        #if os(macOS)
        guard let webView, let r = webView.window?.firstResponder as? NSView else { return false }
        return r === webView || r.isDescendant(of: webView)
        #else
        return webView?.isFirstResponder ?? false
        #endif
    }

    /// Текущий HTML без ожидания debounce — перед уходом со страницы.
    func flush() async -> String? {
        guard let webView else { return nil }
        return try? await webView.evaluateJavaScript("nd.flush()") as? String
    }
}

/// Вложение заметки, которого нет в тексте: видео (вместо GIF) или файл.
struct EditorFile: Encodable, Equatable {
    var id: String
    var name: String
    var video: Bool
    /// Видео целиком (base64): по прямой ссылке на NAS WebKit показывал чёрный кадр.
    var data: String?
    var mime: String?
    /// «1,2 МБ» — для плашки файла
    var size: String?
}

/// Что сделать с картинкой или вложением из контекстного меню.
enum EditorFileAction { case copy, save, open, preview, delete }

/// Настройки отображения из окна «Настройки».
struct EditorPrefs: Equatable {
    var fontSize = 16
    var spellcheck = true
}

/// WKWebView с contenteditable. `documentKey` — идентичность документа:
/// при его смене содержимое перезагружается полностью.
struct HTMLEditor {
    var documentKey: UUID
    var html: String
    var images: [String: String]
    var editable: Bool
    var baseURL: URL?
    var controller: EditorController
    var prefs = EditorPrefs()
    var files: [EditorFile] = []
    /// Вставлена картинка: ref, имя файла, MIME, данные.
    var onImage: (String, String, String, Data) -> Void = { _, _, _, _ in }
    /// Действие над картинкой (ref) или вложением (id файла).
    var onFileAction: (EditorFileAction, _ ref: String?, _ fileID: String?) -> Void = { _, _, _ in }
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    fileprivate func makeWebView(_ c: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(c), name: "nd")
        // Видео-вложения играют сами, как GIF (без звука)
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = c
        #if DEBUG
        wv.isInspectable = true
        #endif
        #if os(macOS)
        wv.setValue(false, forKey: "drawsBackground")
        #else
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.keyboardDismissMode = .interactive
        #endif
        c.webView = wv
        controller.webView = wv
        c.controller = controller
        wv.loadHTMLString(EditorPage.html, baseURL: baseURL)
        return wv
    }

    fileprivate func update(_ c: Coordinator) {
        c.onChange = onChange
        c.onImage = onImage
        c.onFileAction = onFileAction
        controller.webView = c.webView
        c.controller = controller
        c.apply(key: documentKey, html: html, images: images, editable: editable)
        c.applyExtras(prefs: prefs, files: files)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onChange: (String) -> Void
        var onImage: (String, String, String, Data) -> Void = { _, _, _, _ in }
        var onFileAction: (EditorFileAction, String?, String?) -> Void = { _, _, _ in }
        weak var webView: WKWebView?
        private var appliedPrefs: EditorPrefs?
        private var appliedFiles: [EditorFile]?
        private var wantedExtras: (EditorPrefs, [EditorFile])?
        weak var controller: EditorController?
        private var ready = false
        private var loadedKey: UUID?
        /// Последний HTML, который мы знаем (загрузили или получили от редактора).
        private var knownHTML: String?
        private var knownImages: [String: String] = [:]
        private var pending: (UUID, String, [String: String], Bool)?

        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func apply(key: UUID, html: String, images: [String: String], editable: Bool) {
            guard ready, let webView else { pending = (key, html, images, editable); return }
            if key != loadedKey || html != knownHTML {
                loadedKey = key
                knownHTML = html
                knownImages = images
                editorLog.debug("load \(html.count, privacy: .public) chars, \(images.count, privacy: .public) images")
                webView.evaluateJavaScript("nd.load(\(Self.js(html)), \(Self.js(images)))") { _, error in
                    if let error { editorLog.error("nd.load failed: \(error.localizedDescription, privacy: .public)") }
                }
            } else if images != knownImages {
                knownImages = images
                webView.evaluateJavaScript("nd.setImages(\(Self.js(images)))")
            }
            webView.evaluateJavaScript("nd.setEditable(\(editable))")
        }

        func applyExtras(prefs: EditorPrefs, files: [EditorFile]) {
            guard ready, let webView else { wantedExtras = (prefs, files); return }
            if prefs != appliedPrefs {
                appliedPrefs = prefs
                webView.evaluateJavaScript("nd.setPrefs(\(prefs.fontSize), \(prefs.spellcheck))")
            }
            if files != appliedFiles {
                appliedFiles = files
                webView.evaluateJavaScript("nd.setFiles(\(Self.js(files)))")
            }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "log":
                editorLog.error("\(String(describing: body["body"] ?? ""), privacy: .public)")
            case "ready":
                editorLog.debug("editor ready, pending=\(self.pending != nil, privacy: .public)")
                ready = true
                if let p = pending { pending = nil; apply(key: p.0, html: p.1, images: p.2, editable: p.3) }
                if let x = wantedExtras { wantedExtras = nil; applyExtras(prefs: x.0, files: x.1) }
            case "changed":
                guard let html = body["body"] as? String, html != knownHTML else { return }
                knownHTML = html
                onChange(html)
            case "image":
                guard let b = body["body"] as? [String: Any],
                      let ref = b["ref"] as? String, let name = b["name"] as? String,
                      let mime = b["mime"] as? String, let b64 = b["data"] as? String,
                      let data = Data(base64Encoded: b64) else { return }
                onImage(ref, name, mime, data)
            case "state":
                controller?.state = (body["body"] as? [String: Bool]) ?? [:]
            case "menu":
                guard let b = body["body"] as? [String: Any] else { return }
                showMenu(ref: b["ref"] as? String, fileID: b["file"] as? String,
                         x: (b["x"] as? Double) ?? 0, y: (b["y"] as? Double) ?? 0)
            case "openFile":
                if let id = body["body"] as? String { onFileAction(.preview, nil, id) }
            case "fetchImage":
                if let s = body["body"] as? String, let url = URL(string: s) { Task { await insertRemoteImage(url) } }
            default: break
            }
        }

        /// Меню картинки чуть правее и ниже курсора — как в сайдбаре.
        private func showMenu(ref: String?, fileID: String?, x: Double, y: Double) {
            #if os(macOS)
            guard let webView else { return }
            let menu = NSMenu()
            let isImage = ref != nil
            func item(_ title: String, _ icon: String, _ action: EditorFileAction) {
                let it = NSMenuItem(title: title, action: #selector(menuFired(_:)), keyEquivalent: "")
                it.target = self
                it.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                it.representedObject = MenuPayload(action: action, ref: ref, fileID: fileID)
                menu.addItem(it)
            }
            if isImage {
                item("Скопировать изображение", "doc.on.doc", .copy)
                item("Сохранить как…", "square.and.arrow.down", .save)
                menu.addItem(.separator())
                item("Просмотр", "eye", .preview)
                item("Открыть в программе", "arrow.up.forward.app", .open)
            } else {
                item("Просмотр", "eye", .preview)
                item("Открыть в программе", "arrow.up.forward.app", .open)
                item("Сохранить как…", "square.and.arrow.down", .save)
                item("Скопировать файл", "doc.on.doc", .copy)
                menu.addItem(.separator())
                item("Удалить вложение…", "trash", .delete)
            }
            let p = NSPoint(x: x + 14, y: webView.isFlipped ? y + 6 : webView.bounds.height - y - 6)
            menu.popUp(positioning: nil, at: p, in: webView)
            #endif
        }

        private final class MenuPayload {
            let action: EditorFileAction; let ref: String?; let fileID: String?
            init(action: EditorFileAction, ref: String?, fileID: String?) { self.action = action; self.ref = ref; self.fileID = fileID }
        }

        @objc private func menuFired(_ sender: AnyObject) {
            #if os(macOS)
            guard let p = (sender as? NSMenuItem)?.representedObject as? MenuPayload else { return }
            onFileAction(p.action, p.ref, p.fileID)
            #endif
        }

        /// GIF по ссылке из браузера: в буфере он уже статичный, поэтому качаем оригинал.
        private func insertRemoteImage(_ url: URL) async {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let mime = (response as? HTTPURLResponse)?.mimeType ?? "image/gif"
                guard mime.hasPrefix("image/"), data.count < 25_000_000 else { return }
                let name = url.lastPathComponent.isEmpty ? "image.gif" : url.lastPathComponent
                _ = try? await webView?.evaluateJavaScript("nd.insertFile(\(Self.js(data.base64EncodedString())), \(Self.js(mime)), \(Self.js(name)))")
            } catch {
                editorLog.error("fetch image: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Ссылки из заметки открываем в браузере, а не внутри редактора
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        private static func js<T: Encodable>(_ v: T) -> String {
            let data = (try? JSONEncoder().encode(v)) ?? Data("null".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// WKUserContentController держит handler сильно — разрываем цикл.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

#if os(macOS)
extension HTMLEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ v: WKWebView, context: Context) { update(context.coordinator) }
}
#else
extension HTMLEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ v: WKWebView, context: Context) { update(context.coordinator) }
}
#endif

/// Редактор открытой заметки — для команд меню «Правка → Отменить / Повторить».
struct EditorControllerKey: FocusedValueKey { typealias Value = EditorController }

extension FocusedValues {
    var editorController: EditorController? {
        get { self[EditorControllerKey.self] }
        set { self[EditorControllerKey.self] = newValue }
    }
}
