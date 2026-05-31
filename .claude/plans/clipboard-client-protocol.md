# Clipboard Sync — Client ↔ Server Protocol
**Reference for building the settings UI toggle and any future client work.**

---

## The Hub Model

The Mac server is the hub. It never routes clipboard content peer-to-peer — everything
flows through it:

```
iPhone  ──Universal Clipboard──▶  Mac server  ──clipboard-sync──▶  Windows client
Windows ──clipboard-sync────────▶  Mac server  ──clipboard-sync──▶  (all other clients)
```

iPhone→Mac is handled by Apple for free. Mac→iPhone is also Apple. The socket protocol
only covers Mac↔Windows (and Mac↔Android if relevant).

---

## What the Client Sends

**Event:** `clipboard-sync`
**Direction:** client → server
**When:** client clipboard changes and `enableClipboardSync` is true and platform is not iOS/web

```json
{ "content": "the clipboard text" }
```

The server receives this in `socketRoutes.ts`, calls `clipboardService.writeFromClient(content)`,
and responds:
- Success: `clipboard-sync-success` with `{ status: "200", message: null }`
- Error: `clipboard-sync-error` with `{ status: "500", message: "Failed to sync clipboard!" }`

The client currently does not listen for these ack events — it fire-and-forgets via
`SocketSvc.socket?.emit("clipboard-sync", {"content": current})`.

---

## What the Server Sends

**Event:** `clipboard-sync`
**Direction:** server → all clients (broadcast)
**When:** Mac clipboard changes (polled every 500ms) OR a client writes to the Mac clipboard

```json
{ "content": "the clipboard text" }
```

The client receives this via:
1. `socket_service.dart:154` — registers `socket?.on("clipboard-sync", ...)` listener
2. Routes to `MessageHandlerSvc.handleEvent("clipboard-sync", data, 'DartSocket')`
3. `action_handler.dart:173` — `case "clipboard-sync"` calls `ClipboardSyncSvc.handleIncoming(data)`
4. `handleIncoming()` validates content, deduplicates against `_lastKnown`, writes to clipboard

---

## Echo Prevention

Both sides track what they last wrote so they don't re-emit their own changes:

- **Client:** `_lastWritten` — set when `handleIncoming()` writes to local clipboard.
  `_poll()` skips emitting if `current == _lastWritten`.
- **Server:** `lastWritten` — set in `writeFromClient()`. `poll()` skips broadcasting
  if `current === lastWritten`.

---

## Platform Behavior

| Platform | Sends to server | Receives from server |
|----------|----------------|---------------------|
| Windows  | Yes (polls every 1s) | Yes |
| Android  | Yes (polls every 1s) | Yes |
| iOS      | No (`_canSend` = false; Apple handles it) | Yes |
| macOS client | Yes | Yes |
| Web      | No | No |

Guard: `bool get _canSend => !kIsWeb && !(Platform.isIOS);`

---

## Settings Toggle

**Field:** `ss.settings.enableClipboardSync` — `RxBool`, defaults to `false`

**Where defined:** `lib/database/global/settings.dart`

**Effect:** `start()` returns early if false. `_poll()` also checks it each tick,
so toggling off mid-session stops sending immediately without restarting the service.

**Settings UI still TODO** — needs a toggle in the privacy/advanced settings screen.
Use the existing `SettingsSwitchTile` or equivalent from
`lib/app/layouts/settings/widgets/tiles/`.

---

## Key File Locations

| File | Role |
|------|------|
| `lib/services/backend/clipboard_sync_service.dart` | Poll, send, receive, echo prevention |
| `lib/services/network/socket_service.dart:154` | Registers `clipboard-sync` listener |
| `lib/services/backend/action_handler.dart:173` | Routes event to ClipboardSyncSvc |
| `lib/database/global/settings.dart` | `enableClipboardSync` field |
| `lib/helpers/backend/startup_tasks.dart` | Service registered + started |
| `packages/server/src/server/services/clipboardService/index.ts` | Server hub, ring buffer |
| `packages/server/src/trays/AppTray.ts` | Tray history submenu |
| `packages/server/src/server/api/http/api/v1/socketRoutes.ts:1086` | Server receives client events |
