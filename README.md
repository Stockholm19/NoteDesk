# NoteDesk

An unofficial native client for **Synology Note Station** on macOS and iOS, built with SwiftUI.

NoteDesk keeps a local copy of your notes and syncs it with Note Station on your own Synology NAS. You can read and edit notes offline, and changes go to the server on the next sync.

> **Unofficial project.** NoteDesk is not affiliated with, endorsed by, or supported by Synology Inc. "Synology" and "Note Station" are trademarks of Synology Inc. NoteDesk uses Note Station's undocumented web API, so a Note Station update can break it at any time.

## Features

- **Two-way sync** with Note Station: create, edit, move and delete notes; changes made in the web UI or DS note show up here.
- **Offline first**: notes are stored locally with SwiftData; edits are queued and pushed when the NAS is reachable.
- **Safe conflicts**: if a note was changed elsewhere, the server version is kept and your version is saved as a separate "(conflict)" note. Nothing is overwritten.
- **Native HTML editor** that keeps Note Station's own markup: formatting, lists, code blocks, Note Station-compatible checkboxes, undo/redo (⌘Z / ⇧⌘Z) for every kind of edit.
- **Images**: inline images from the NAS, paste or drag-and-drop new ones (uploaded as note attachments), resize by dragging a corner or with presets. Animated GIFs stay GIFs; a GIF copied from a browser is downloaded from its original URL.
- **Attachments**: files attached to a note are listed under the text; attach new files, preview (Quick Look), open, save, copy or delete them. Short videos (Telegram-style "GIFs", stored by Note Station as mp4) play inline, muted and looped.
- **Right-click on an image or attachment** (macOS): copy, save as, preview, open.
- **Notebooks like in Note Station**: stacks ("shelves"), Favorites, default notebook, archive; context menus to rename, move to a stack, remove from a shelf, delete, set as default, archive. "Create" menu: note, note in a notebook, notebook, shelf.
- **Tags as a tree** (`parent/child` names), search, sorting by modified/created date or title, month sections, note thumbnails.
- **Trash**: browse, preview, restore, delete forever, empty.
- **Settings** (⌘,): account, editor font size, spell check, sync interval.
- **Two-factor authentication** with a trusted-device token, so you are not asked for a code on every re-login.

Not supported yet: encrypted notes (shown as locked), editing tags, smart notebooks, sharing, the to-do list, import/export (use the Note Station web UI for those). On iOS there is no right-click menu for images.

## Requirements

- Synology DSM 7.x with Note Station 2.6 (tested with 2.6.10)
- macOS 14+ / iOS 17+
- Xcode 26+ to build

## Building

1. Open `App/NoteDesk.xcodeproj`.
2. In **Signing & Capabilities**, select your own team and change the bundle identifier.
3. Choose **My Mac** or an iPhone and press Run.

From the command line (use `xcrun`, a toolchain from swiftly in `PATH` breaks the build):

```sh
xcodebuild -project App/NoteDesk.xcodeproj -scheme NoteDesk -derivedDataPath .dd -destination 'platform=macOS' build
xcodebuild -project App/NoteDesk.xcodeproj -scheme NoteDesk -derivedDataPath .dd -destination 'generic/platform=iOS Simulator' build
open .dd/Build/Products/Debug/NoteDesk.app
```

`NoteStationKit` is a local Swift package with the API client and a small CLI, `nsctl`, for poking the API:

```sh
cd NoteStationKit
xcrun swift build --product nsctl
.build/debug/nsctl login http://192.168.1.10:5000 admin
.build/debug/nsctl notebooks
.build/debug/nsctl notes 20
.build/debug/nsctl note <object_id>
.build/debug/nsctl raw SYNO.NoteStation.Note list '{"offset":0,"limit":5,"filter":{"recycle":true}}' 3
```

The session is stored in `~/Library/Application Support/NoteDesk/nsctl-session.json` (mode 600). The app stores credentials in the Keychain.

## Project layout

```
App/                          SwiftUI app (one target for macOS and iOS)
  NoteDesk/NoteDeskApp.swift  App, Settings scene, background sync loop
  NoteDesk/Sync/              SyncEngine (push, then pull), Keychain account, thumbnail cache
  NoteDesk/Store/             SwiftData models of the local copy
  NoteDesk/Editor/            EditorPage (HTML + CSS + JS in one raw string), HTMLEditor (WKWebView bridge)
  NoteDesk/Views/             Sidebar, note list, note editor, trash, create sheets, settings, context menus
NoteStationKit/               Swift package: DSM / Note Station API client, nsctl
```

## How it works

### Sync (`SyncEngine`)

- The local SwiftData store is a cache of the server. If its schema can't be opened, it is deleted and downloaded again (`NoteDeskApp`). New model properties must have default values.
- `sync()` = **push** local changes, then **pull**. Only one sync runs at a time; a request during a sync schedules another one.
- Push: notes with `isDirty` are sent with `Note.set` and `check_conflict: true` against `remoteVer`. Error 1064 → `resolveConflict` keeps the server version and saves ours as a new "(conflict …)" note. Notes with `isTrashedLocally` are moved to the server trash.
- After a successful write only the version is taken from the server (`markPushed`); the local HTML is never replaced, because the user may have kept typing during the request.
- Pull: notebooks, shortcuts (Favorites), the note list (no bodies), then bodies of changed notes in parallel chunks of 8. One broken note (error 1033) does not stop the sync.
- New images are stored as `PendingAttachment` until they are uploaded together with the note text (multipart `Note.set`).
- Attaching or deleting a file first waits for a full sync, then calls the API and refreshes `remoteVer`; otherwise the next push would be a false conflict.
- The trash is not stored locally; it is read from the server when opened.

### Editor (`EditorPage`, `HTMLEditor`)

- A `contenteditable` page inside `WKWebView`. The HTML from Note Station is loaded as is and saved back as is: the editor does not convert formats.
- Everything the editor changes only for display (image `src`, checkbox images) keeps the original value in `data-nd-src`; `serialize()` puts it back. Never save `ed.innerHTML` directly.
- `nd.load` sets a baseline; `nd.flush()` returns `null` if nothing changed, so opening a note never rewrites it on the server.
- JS → Swift messages (`window.webkit.messageHandlers.nd`): `ready`, `changed`, `state`, `image`, `menu`, `openFile`, `fetchImage`, `log`. Swift → JS: `nd.load`, `setImages`, `setEditable`, `setPrefs`, `setFiles`, `insertFile`, `exec`, `flush`.
- Undo/redo is the editor's own history (snapshots of HTML and caret before each edit), because checkboxes, images and resizing change the DOM directly and are invisible to WebKit's undo stack. Any new code that changes the DOM must call `record('<kind>')` first.
- Attachments that are not referenced in the text are rendered in `#nd-files`, outside the editable area, so they never get into the note HTML.
- The editor JS can be tested in a desktop browser: extract the string between `#"""` and `"""#`, stub `window.webkit.messageHandlers.nd`, and drive it with Playwright.

## Note Station API notes

Reverse-engineered from the Note Station 2.6 web UI (`notestation.js`) and verified against a live NAS.

All calls are `POST /webapi/entry.cgi`. Note Station APIs use `requestFormat=JSON`, so **every parameter value is sent as JSON text**: a string `abc` is sent as `"abc"`, a boolean as `true`. Multipart requests put `api`, `method`, `version` in the query string.

| Action | API / method / version | Parameters / notes |
|---|---|---|
| Notebooks | `Notebook.list` v2 | each notebook has `stack`, `preset` (default notebook), `archive` |
| Create notebook | `Notebook.create` v2 | `title`, `commit_msg` |
| Rename / move to stack | `Notebook.set` v2 | `object_id`, `title` or `stack` (`""` = remove from shelf). Renaming or ungrouping a stack = set `stack` on each notebook; `Stack.set`/`Stack.delete` return error 114 |
| Default notebook | `Notebook.Preset.set` v1 | `object_id` |
| Archive | `Notebook.Polling.archive` v1 | `object_id`, `enable` → `task_id`; poll `archive_status` until `finish`, then `archive_stop` |
| Delete notebook | `Notebook.delete` v2 | `object_id`, `recursive: false` (notes go to the trash; `true` deletes them permanently) |
| Notes | `Note.list` v3 | `offset`, `limit` — **`total` is the page size, not the overall count**; page until a short page. No tags in the list. `thumb.md5` if there is a preview |
| Trash | `Note.list` v3 | plus `filter: {recycle: true}` |
| Note | `Note.get` v3 | `object_id` → `content` (HTML), `tag[]`, `attachment{file_id: {ref, name, type, size, …}}`, `ver` |
| Create | `Note.create` v3 | `title`, `parent_id`, `content`, `brief`, `commit_msg` (attachments are not accepted here) |
| Update | `Note.set` v3 | `object_id`, `ver`, `check_conflict: true`, … → error **1064** if `ver` is stale |
| Upload attachments | `Note.set` v3, multipart | `attachment: [{action: "create", format: "raw", name: <form field>, ref?}]` plus the files. With `ref` it is an inline image, without — a plain attached file |
| Delete attachment | `Note.set` v3 | `attachment: [{action: "delete", file_id}]` |
| Move to trash | `Note.delete` v3 | `object_id`, `recycle: true` (`recycle` in `Note.set` is ignored) |
| Restore | `Note.restore` v3 | `object_id` — back to its notebook |
| Delete forever | `Note.delete` v3 | `object_id`, `recycle: false` on a note in the trash |
| Download attachment | `Note.download` v3 (GET) | `object_id`, `file_id`, `format: "raw"` |
| Thumbnail | `Note.download` v3 (GET) | `file_id: "thumb"`, `md5`, `filename: "thumb.png"` |
| Favorites | `Shortcut.list` / `set` / `delete` v1 | `object_id` for notes and notebooks, `stack_id` = `"Name#uid"`, `tag_id` = `"Title@uid"` |

Markup details:

- Images: `<img class="syno-notestation-image-object" src="webman/3rdparty/NoteStation/images/transparent.gif" ref="…">`, where `ref` matches `attachment[file_id].ref`. A new `ref` is `base64(timestamp + filename)`. Size is stored in `width`/`height` attributes.
- Checkboxes: `<input type="image" class="syno-notestation-editor-checkbox">`, plus `syno-notestation-editor-checkbox-checked` when checked.
- Code blocks are plain `<pre>`.
- Telegram "GIFs" are stored as a static PNG in the text plus an mp4 attachment that is not referenced in the text.
- Error 1033 (`drive_get_failed`) means Note Station itself cannot read the note from its storage.

## Working on the code

- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Subclassing AppKit classes with `init` overrides breaks this; prefer composition (see `ContextMenu.swift`).
- The app is sandboxed: outgoing network and user-selected files (read/write) are enabled; anything else needs a new entitlement.
- Keep solutions simple and cheap to maintain: this is a one-person project.
- Test API changes with `nsctl raw` on a separate test notebook before using them in the app; some methods behave differently from what the web UI code suggests (see the table above).
- Build both macOS and iOS before committing.
- Commit messages: short English summary plus a bullet list. No AI attribution trailers (`Co-Authored-By`, session links and the like).

## License

[MIT](LICENSE)
