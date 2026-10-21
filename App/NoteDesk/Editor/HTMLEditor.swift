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

    /// Текущий HTML без ожидания debounce — перед уходом со страницы.
    func flush() async -> String? {
        guard let webView else { return nil }
        return try? await webView.evaluateJavaScript("nd.flush()") as? String
    }
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
    /// Вставлена картинка: ref, имя файла, MIME, данные.
    var onImage: (String, String, String, Data) -> Void = { _, _, _, _ in }
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    fileprivate func makeWebView(_ c: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(c), name: "nd")
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
        controller.webView = c.webView
        c.controller = controller
        c.apply(key: documentKey, html: html, images: images, editable: editable)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onChange: (String) -> Void
        var onImage: (String, String, String, Data) -> Void = { _, _, _, _ in }
        weak var webView: WKWebView?
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

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "log":
                editorLog.error("\(String(describing: body["body"] ?? ""), privacy: .public)")
            case "ready":
                editorLog.debug("editor ready, pending=\(self.pending != nil, privacy: .public)")
                ready = true
                if let p = pending { pending = nil; apply(key: p.0, html: p.1, images: p.2, editable: p.3) }
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
            default: break
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
