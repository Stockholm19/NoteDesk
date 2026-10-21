import Foundation

/// Сессия DSM: всё, что нужно, чтобы продолжить работу без пароля.
public struct DSMSession: Codable, Sendable, Equatable {
    public var baseURL: URL
    public var account: String
    public var sid: String
    public var synoToken: String?
    /// Токен доверенного устройства — позволяет перелогиниваться без кода 2FA.
    public var deviceID: String?

    public init(baseURL: URL, account: String, sid: String, synoToken: String?, deviceID: String?) {
        self.baseURL = baseURL
        self.account = account
        self.sid = sid
        self.synoToken = synoToken
        self.deviceID = deviceID
    }
}

public struct APIInfo: Sendable, Hashable {
    public var path: String
    public var minVersion: Int
    public var maxVersion: Int
    public var jsonRequest: Bool
}

public enum DSMError: Error, LocalizedError, Sendable, Equatable {
    case badURL
    case http(Int)
    case malformedResponse
    case apiMissing(String)
    case api(code: Int, api: String, method: String)
    case notLoggedIn

    /// Сессия истекла или недействительна — нужно перелогиниться.
    public var isSessionError: Bool {
        switch self {
        case .notLoggedIn: return true
        case .api(let code, _, _): return [105, 106, 107, 119].contains(code)
        default: return false
        }
    }

    public var code: Int? {
        if case .api(let code, _, _) = self { return code }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .badURL: return "Неверный адрес сервера"
        case .http(let s): return "HTTP \(s)"
        case .malformedResponse: return "Сервер вернул неожиданный ответ"
        case .apiMissing(let api): return "На сервере нет \(api) — Note Station установлен и запущен?"
        case .notLoggedIn: return "Нужно войти"
        case .api(let code, let api, let method):
            if api == "SYNO.API.Auth" {
                switch code {
                case 400: return "Неверный логин или пароль"
                case 401: return "Учётная запись отключена"
                case 402: return "Нет доступа"
                case 403: return "Нужен код двухфакторной аутентификации"
                case 404: return "Неверный код 2FA"
                case 406: return "На сервере обязательна 2FA — включите её для учётной записи"
                case 407: return "IP заблокирован после неудачных попыток входа"
                case 408, 409, 410: return "Пароль истёк — смените его в DSM"
                default: break
                }
            }
            switch code {
            case 105, 106, 107, 119: return "Сессия истекла"
            case 1064: return "Заметку изменили на другом устройстве"
            case 1033: return "Note Station не может прочитать эту заметку из хранилища (drive_get_failed) — проверьте её в веб-версии"
            case 1008, 1048, 1054: return "Заметка не найдена на сервере"
            case 1020, 1023, 1028: return "Нет доступа к заметке"
            default: return "\(api).\(method): ошибка \(code)"
            }
        }
    }
}

/// Низкоуровневый клиент Synology Web API (query.cgi / entry.cgi).
public actor DSMClient {
    public let baseURL: URL
    public private(set) var session: DSMSession?
    private var apis: [String: APIInfo] = [:]
    private let urlSession: URLSession

    public init(baseURL: URL, session: DSMSession? = nil, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.urlSession = urlSession
    }

    // MARK: Discovery

    @discardableResult
    public func discover() async throws -> [String: APIInfo] {
        if !apis.isEmpty { return apis }
        let data = try await raw(path: "query.cgi", fields: [
            "api": "SYNO.API.Info", "version": "1", "method": "query",
            "query": "SYNO.API.Auth,SYNO.NoteStation.",
        ], api: "SYNO.API.Info", method: "query")
        guard let obj = data.object else { throw DSMError.malformedResponse }
        var result: [String: APIInfo] = [:]
        for (name, v) in obj {
            guard let path = v["path"]?.string, let maxV = v["maxVersion"]?.int else { continue }
            result[name] = APIInfo(
                path: path,
                minVersion: v["minVersion"]?.int ?? 1,
                maxVersion: maxV,
                jsonRequest: v["requestFormat"]?.string == "JSON")
        }
        apis = result
        return result
    }

    public func info(_ api: String) async throws -> APIInfo {
        try await discover()
        guard let i = apis[api] else { throw DSMError.apiMissing(api) }
        return i
    }

    // MARK: Auth

    public func login(account: String, password: String, otp: String? = nil, deviceName: String = "NoteDesk") async throws -> DSMSession {
        let auth = try await info("SYNO.API.Auth")
        var fields: [String: String] = [
            "api": "SYNO.API.Auth",
            "version": String(min(auth.maxVersion, 6)),
            "method": "login",
            "account": account,
            "passwd": password,
            "session": "NoteStation",
            "format": "sid",
            "enable_syno_token": "yes",
        ]
        if let otp, !otp.isEmpty {
            fields["otp_code"] = otp
            fields["enable_device_token"] = "yes"
            fields["device_name"] = deviceName
        } else if let did = session?.deviceID, session?.account == account {
            fields["device_id"] = did
            fields["device_name"] = deviceName
        }
        let data = try await raw(path: auth.path, fields: fields, api: "SYNO.API.Auth", method: "login")
        guard let sid = data["sid"]?.string else { throw DSMError.malformedResponse }
        let newSession = DSMSession(
            baseURL: baseURL, account: account, sid: sid,
            synoToken: data["synotoken"]?.string,
            deviceID: data["did"]?.string ?? data["device_id"]?.string ?? session?.deviceID)
        session = newSession
        return newSession
    }

    public func logout() async {
        guard session != nil, let auth = try? await info("SYNO.API.Auth") else { return }
        _ = try? await raw(path: auth.path, fields: [
            "api": "SYNO.API.Auth", "version": "1", "method": "logout", "session": "NoteStation",
        ], api: "SYNO.API.Auth", method: "logout")
        session = nil
    }

    public func setSession(_ s: DSMSession?) { session = s }

    // MARK: Calls

    /// Вызов API. Для API с requestFormat=JSON каждое значение параметра
    /// кодируется как JSON-текст — ровно так делает веб-интерфейс DSM.
    public func call(_ api: String, _ method: String, version: Int? = nil,
                     _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard session != nil else { throw DSMError.notLoggedIn }
        let i = try await info(api)
        var fields: [String: String] = [
            "api": api, "method": method,
            "version": String(min(version ?? i.maxVersion, i.maxVersion)),
        ]
        for (k, v) in params {
            fields[k] = i.jsonRequest ? v.jsonText : (v.stringish ?? v.jsonText)
        }
        return try await raw(path: i.path, fields: fields, api: api, method: method)
    }

    /// GET-URL, который можно отдать WKWebView/URLSession (например, картинка из заметки).
    public func url(_ api: String, _ method: String, version: Int? = nil,
                    _ params: [String: JSONValue] = [:]) async throws -> URL {
        guard let s = session else { throw DSMError.notLoggedIn }
        let i = try await info(api)
        var items = [
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "version", value: String(min(version ?? i.maxVersion, i.maxVersion))),
        ]
        for (k, v) in params.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: k, value: i.jsonRequest ? v.jsonText : (v.stringish ?? v.jsonText)))
        }
        items.append(URLQueryItem(name: "_sid", value: s.sid))
        if let t = s.synoToken { items.append(URLQueryItem(name: "SynoToken", value: t)) }
        var comps = URLComponents(url: baseURL.appending(path: "webapi/\(i.path)"), resolvingAgainstBaseURL: false)
        comps?.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value.map(Self.formEncode))
        }
        guard let u = comps?.url else { throw DSMError.badURL }
        return u
    }

    /// Скачать бинарные данные (вложение, картинку).
    public func download(_ api: String, _ method: String, version: Int? = nil,
                         _ params: [String: JSONValue] = [:]) async throws -> Data {
        let u = try await url(api, method, version: version, params)
        let (data, resp) = try await urlSession.data(from: u)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw DSMError.http(h.statusCode) }
        // DSM при ошибке отдаёт JSON вместо файла
        if let first = data.first, first == UInt8(ascii: "{"),
           let v = try? JSONDecoder().decode(JSONValue.self, from: data),
           v["success"]?.bool == false {
            throw DSMError.api(code: v["error"]?["code"]?.int ?? -1, api: api, method: method)
        }
        return data
    }

    private func raw(path: String, fields: [String: String], api: String, method: String) async throws -> JSONValue {
        var req = URLRequest(url: baseURL.appending(path: "webapi/\(path)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body = fields
        if let s = session, api != "SYNO.API.Info" {
            body["_sid"] = s.sid
            if let t = s.synoToken { req.setValue(t, forHTTPHeaderField: "X-SYNO-TOKEN") }
        }
        req.httpBody = Data(body.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&").utf8)

        let (data, resp) = try await urlSession.data(for: req)
        return try Self.decode(data, resp, api: api, method: method)
    }

    private static func decode(_ data: Data, _ resp: URLResponse, api: String, method: String) throws -> JSONValue {
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw DSMError.http(h.statusCode) }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DSMError.malformedResponse
        }
        if json["success"]?.bool == true { return json["data"] ?? .null }
        throw DSMError.api(code: json["error"]?["code"]?.int ?? -1, api: api, method: method)
    }

    /// Файл для multipart-загрузки.
    public struct UploadFile: Sendable {
        public var field: String
        public var filename: String
        public var mimeType: String
        public var data: Data
        public init(field: String, filename: String, mimeType: String, data: Data) {
            self.field = field; self.filename = filename; self.mimeType = mimeType; self.data = data
        }
    }

    /// Вызов с файлами — как html5upload в веб-интерфейсе DSM: api/method/version
    /// в query, параметры (JSON-текстом) и файлы — в multipart-теле.
    public func upload(_ api: String, _ method: String, version: Int? = nil,
                       _ params: [String: JSONValue], files: [UploadFile]) async throws -> JSONValue {
        guard let s = session else { throw DSMError.notLoggedIn }
        let i = try await info(api)
        var items = [
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "version", value: String(min(version ?? i.maxVersion, i.maxVersion))),
            URLQueryItem(name: "_sid", value: s.sid),
        ]
        if let t = s.synoToken { items.append(URLQueryItem(name: "SynoToken", value: t)) }
        var comps = URLComponents(url: baseURL.appending(path: "webapi/\(i.path)"), resolvingAgainstBaseURL: false)
        comps?.percentEncodedQueryItems = items.map { URLQueryItem(name: $0.name, value: $0.value.map(Self.formEncode)) }
        guard let url = comps?.url else { throw DSMError.badURL }

        let boundary = "NoteDesk-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in params.sorted(by: { $0.key < $1.key }) {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            add(i.jsonRequest ? v.jsonText : (v.stringish ?? v.jsonText))
            add("\r\n")
        }
        for f in files {
            let name = f.filename.replacingOccurrences(of: "\"", with: "_")
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.field)\"; filename=\"\(name)\"\r\n")
            add("Content-Type: \(f.mimeType)\r\n\r\n")
            body.append(f.data)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let t = s.synoToken { req.setValue(t, forHTTPHeaderField: "X-SYNO-TOKEN") }
        let (data, resp) = try await urlSession.upload(for: req, from: body)
        return try Self.decode(data, resp, api: api, method: method)
    }

    // Только ASCII: CharacterSet.alphanumerics пропустил бы кириллицу без кодирования.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
