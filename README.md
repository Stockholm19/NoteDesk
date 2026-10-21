# NoteDesk

Клиент Synology Note Station для macOS и iOS (SwiftUI), работает с локальной копией заметок и синхронизирует её с NAS.

## Структура

- `NoteStationKit/` — Swift-пакет: клиент DSM Web API и Note Station API, без зависимостей.
  - `nsctl` — консольная утилита для отладки API (`.build/debug/nsctl` без аргументов выводит список команд).
- `App/` — мультиплатформенное приложение (один таргет на Mac и iOS).
  - `Sync/SyncEngine.swift` — синхронизация: push локальных правок → pull изменений с сервера.
  - `Editor/` — редактор: WKWebView с contenteditable поверх родного HTML Note Station.
  - `Store/LocalModels.swift` — SwiftData-модели локальной копии.

Сборка: открыть `App/NoteDesk.xcodeproj`, схема NoteDesk, выбрать Mac или iPhone.
Пакет из терминала собирать через `xcrun swift build`: swiftly-тулчейн в PATH не совпадает с SDK Xcode.

## Note Station API (снято с notestation.js 2.6.10, проверено на живом NAS)

Все вызовы идут через `POST /webapi/entry.cgi`. У API Note Station `requestFormat=JSON`, поэтому каждое значение параметра передаётся как JSON-текст: строка — `"\"abc\""`, bool — `true`.

| Действие | API / метод / версия | Параметры |
|---|---|---|
| Блокноты | `Notebook.list` v2 | — |
| Создать блокнот | `Notebook.create` v2 | `title`, `commit_msg` |
| Заметки | `Note.list` v3 | `offset`, `limit` — **`total` в ответе = размер страницы**, листать до неполной страницы. Тегов в списке нет |
| Заметка | `Note.get` v3 | `object_id` → `content` (HTML), `tag[]`, `attachment{file_id: {ref, type, …}}`, `ver` |
| Создать | `Note.create` v3 | `title`, `parent_id`, `content`, `brief`, `commit_msg` |
| Изменить | `Note.set` v3 | `object_id`, `ver`, `check_conflict: true`, … → ошибка **1064**, если `ver` устарела |
| В корзину | `Note.delete` v3 | `object_id`, `recycle: true` (флаг `recycle` в `Note.set` игнорируется) |
| Вложение | `Note.download` v3 (GET) | `object_id`, `file_id`, `format: "raw"` |

Картинки в HTML: `<img class="syno-notestation-image-object" src="webman/3rdparty/NoteStation/images/transparent.gif" ref="…">`. `ref` указывает на `attachment[file_id].ref`. Редактор подменяет `src` на URL скачивания, а при сохранении возвращает исходный.

## Синхронизация

- Локальные правки помечаются `isDirty`, через 3 с после правки, раз в минуту и при возврате в приложение идёт синхронизация.
- Конфликт (1064): серверная версия остаётся в заметке, локальная сохраняется отдельной заметкой «… (конфликт дата)». Ничего не теряется.
- Сессия истекла: тихий перелогин паролем из Keychain; 2FA не спрашивается повторно благодаря device token.

## Не сделано / ограничения

- Зашифрованные заметки только помечаются замком (расшифровка — CryptoJS AES, можно добавить).
- Добавление картинок и файлов из приложения (нужен multipart в `Note.set`).
- Редактирование тегов, корзина, офлайн-кэш картинок.
- Перед App Store: заменить `NSAllowsArbitraryLoads` на `NSAllowsLocalNetworking`, убрать «Synology/Note Station» из названия.
