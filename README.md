# NoteDesk

An unofficial native client for **Synology Note Station** on macOS and iOS, built with SwiftUI.

NoteDesk keeps a local copy of your notes and syncs it with Note Station on your own Synology NAS. You can read and edit notes offline, and changes go to the server on the next sync.

> **Unofficial project.** NoteDesk is not affiliated with, endorsed by, or supported by Synology Inc. "Synology" and "Note Station" are trademarks of Synology Inc. NoteDesk uses Note Station's undocumented web API, so a Note Station update can break it at any time.

## Features

- **Two-way sync** with Note Station: create, edit, move and delete notes; changes made in the web UI or DS note show up here.
- **Offline first**: notes are stored locally with SwiftData; edits are queued and pushed when the NAS is reachable.
- **Safe conflicts**: if a note was changed elsewhere, the server version is kept and your version is saved as a separate "(conflict)" note. Nothing is overwritten.
- **Native HTML editor** that keeps Note Station's own markup: formatting, lists, code blocks, Note Station-compatible checkboxes.
- **Images**: inline images from the NAS, paste or drag-and-drop new ones (uploaded as note attachments), resize by dragging a corner or with presets. Sizes are stored the same way Note Station stores them.
- **Notebook stacks and Favorites** like in Note Station, tags, search, sorting by modified/created date or title, month sections.
- **Two-factor authentication** with a trusted-device token, so you are not asked for a code on every re-login.

Not supported yet: encrypted notes (shown as locked), editing tags, non-image attachments, the trash.

## Requirements

- Synology DSM 7.x with Note Station 2.6 (tested with 2.6.10)
- macOS 14+ / iOS 17+
- Xcode 26+ to build

## Building

1. Open `App/NoteDesk.xcodeproj`.
2. In **Signing & Capabilities**, select your own team and change the bundle identifier.
3. Choose **My Mac** or an iPhone and press Run.

`NoteStationKit` is a local Swift package with the API client and a small CLI, `nsctl`, for poking the API:

```sh
cd NoteStationKit
xcrun swift build --product nsctl
.build/debug/nsctl login http://192.168.1.10:5000 admin
.build/debug/nsctl notebooks
.build/debug/nsctl notes 20
```

The session is stored in `~/Library/Application Support/NoteDesk/nsctl-session.json` (mode 600). The app stores credentials in the Keychain.

## Project layout

```
App/                      SwiftUI app (one target for macOS and iOS)
  NoteDesk/Sync/          SyncEngine: push local edits, then pull server changes
  NoteDesk/Editor/        WKWebView-based contenteditable editor
  NoteDesk/Store/         SwiftData models of the local copy
  NoteDesk/Views/         Sidebar, note list, note editor, login
NoteStationKit/           Swift package: DSM / Note Station API client, nsctl
```

## Note Station API notes

Reverse-engineered from the Note Station 2.6 web UI and verified against a live NAS.

All calls are `POST /webapi/entry.cgi`. Note Station APIs use `requestFormat=JSON`, so **every parameter value is sent as JSON text**: a string `abc` is sent as `"abc"`, a boolean as `true`.

| Action | API / method / version | Parameters |
|---|---|---|
| Notebooks | `Notebook.list` v2 | — (each notebook has a `stack` name) |
| Create notebook | `Notebook.create` v2 | `title`, `commit_msg` |
| Notes | `Note.list` v3 | `offset`, `limit` — **`total` is the page size, not the overall count**; page until a short page. Tags are not included |
| Note | `Note.get` v3 | `object_id` → `content` (HTML), `tag[]`, `attachment{file_id: {ref, type, …}}`, `ver` |
| Create | `Note.create` v3 | `title`, `parent_id`, `content`, `brief`, `commit_msg` |
| Update | `Note.set` v3 | `object_id`, `ver`, `check_conflict: true`, … → error **1064** if `ver` is stale |
| Update with images | `Note.set` v3, multipart | as above plus `attachment: [{action: "create", format: "raw", name, ref}]` and the files |
| Move to trash | `Note.delete` v3 | `object_id`, `recycle: true` (`recycle` in `Note.set` is ignored) |
| Attachment | `Note.download` v3 (GET) | `object_id`, `file_id`, `format: "raw"` |
| Favorites | `Shortcut.list` v1 | `category` (notebook, note, tag, stack) and `id` |

Markup details:

- Images: `<img class="syno-notestation-image-object" src="webman/3rdparty/NoteStation/images/transparent.gif" ref="…">`, where `ref` matches `attachment[file_id].ref`. A new `ref` is `base64(timestamp + filename)`. Size is stored in `width`/`height` attributes.
- Checkboxes: `<input type="image" class="syno-notestation-editor-checkbox">`, plus `syno-notestation-editor-checkbox-checked` when checked.
- Error 1033 (`drive_get_failed`) means Note Station itself cannot read the note from its storage.

## License

[MIT](LICENSE)
