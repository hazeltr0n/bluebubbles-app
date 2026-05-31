# Clipboard Sync — Windows Native Method Channel
**Pick this up on the Windows machine. Branch: `feature/my-features`**

## Context
BlueBubbles clipboard sync is partially built. The server (Mac) and cross-platform
client are done. This plan covers the Windows-specific Win+V integration.

## What's already built (don't re-do)
- `lib/services/backend/clipboard_sync_service.dart` — polls clipboard, sends/receives
  `clipboard-sync` socket events, handles incoming from server
- `lib/database/global/settings.dart` — `enableClipboardSync` RxBool field added
- `lib/services/network/socket_service.dart` — `clipboard-sync` listener registered
- `lib/services/backend/action_handler.dart` — `clipboard-sync` case routes to `ClipboardSyncSvc`
- `lib/services/services.dart` — `ClipboardSyncService` exported
- `lib/helpers/backend/startup_tasks.dart` — service registered + started at startup

## What to build here

### 1. Windows native C++ method channel
**New file: `windows/runner/clipboard_channel.h`**
```cpp
#ifndef CLIPBOARD_CHANNEL_H_
#define CLIPBOARD_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <string>
#include <vector>

class ClipboardChannel {
 public:
  explicit ClipboardChannel(flutter::BinaryMessenger* messenger);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

#endif  // CLIPBOARD_CHANNEL_H_
```

**New file: `windows/runner/clipboard_channel.cpp`**
- Channel name: `"com.bluebubbles.clipboard"`
- Handle method: `"getClipboardHistory"`
  - Check `Clipboard::IsHistoryEnabled()` — if false, return empty list
  - Call `Clipboard::GetHistoryItemsAsync().get()` (sync wait, called infrequently)
  - For each item: get `DataPackageView`, call `GetTextAsync().get()`, collect strings
  - Return `flutter::EncodableList` of up to 20 text strings
- Uses WinRT: `#include <winrt/Windows.ApplicationModel.DataTransfer.h>`
- Uses UTF helpers from `utils.h` already in the project

**Modify: `windows/runner/flutter_window.cpp`**
- In `OnCreate()`, after `RegisterPlugins(...)`, instantiate `ClipboardChannel`:
  ```cpp
  clipboard_channel_ = std::make_unique<ClipboardChannel>(
      flutter_controller_->engine()->messenger());
  ```

**Modify: `windows/runner/flutter_window.h`**
- Add `#include "clipboard_channel.h"`
- Add `std::unique_ptr<ClipboardChannel> clipboard_channel_;` to private members

**Modify: `windows/runner/CMakeLists.txt`**
- Add `clipboard_channel.cpp` to the `add_executable()` sources list
- Add `/std:c++17` to compile options (needed for C++/WinRT)
- Add `/await` flag for WinRT coroutines

### 2. Dart side — call the channel on connect
**Modify: `lib/services/backend/clipboard_sync_service.dart`**

Add a method `_syncWindowsHistory()`:
```dart
Future<void> _syncWindowsHistory() async {
  if (!Platform.isWindows) return;
  try {
    const channel = MethodChannel('com.bluebubbles.clipboard');
    final List<dynamic>? items = await channel.invokeMethod('getClipboardHistory');
    if (items == null || items.isEmpty) return;
    for (final item in items.cast<String>()) {
      SocketSvc.socket?.emit("clipboard-sync-history-item", {"content": item});
    }
  } catch (e) {
    Logger.warn("Failed to read Win+V history: $e", tag: _tag);
  }
}
```

Call `_syncWindowsHistory()` from `start()` on Windows.

Also add a new socket event listener in `socket_service.dart` for
`clipboard-history-ack` if needed (server can confirm receipt).

### 3. Server — add ring buffer + tray submenu
**These changes go in `bluebubbles-server` repo on Mac, branch `feature/my-features`**

Already noted — do this on the Mac side:
- `ClipboardService`: add `history: {text: string, timestamp: number}[]` ring buffer (max 20)
  Push to front on every change (poll or client send). Expose `getHistory()`.
- `AppTray.ts`: in `buildMenu()`, add submenu:
  ```typescript
  {
    label: 'Clipboard History',
    submenu: Server().clipboardService.getHistory().map((item, i) => ({
      label: `${item.text.substring(0, 40)}${item.text.length > 40 ? '…' : ''}`,
      click: () => Server().emitMessage(CLIPBOARD_SYNC, { content: item.text }, 'normal', false)
    }))
  }
  ```

## Testing checklist (on Windows)
- [ ] Win+V history enabled in Windows Settings → System → Clipboard
- [ ] Build runs: `flutter build windows`
- [ ] On app connect, Win+V items appear in server tray submenu
- [ ] Clicking tray item sets clipboard on Windows client
- [ ] Copying on Windows appears in server tray within 1 second

## Key file paths
| File | Purpose |
|------|---------|
| `windows/runner/clipboard_channel.cpp` | NEW — WinRT history reader |
| `windows/runner/clipboard_channel.h` | NEW — header |
| `windows/runner/flutter_window.cpp` | Register channel in OnCreate() |
| `windows/runner/flutter_window.h` | Add member + include |
| `windows/runner/CMakeLists.txt` | Add source + C++17 flags |
| `lib/services/backend/clipboard_sync_service.dart` | Add _syncWindowsHistory() |
| `windows/runner/utils.h` | Already has Utf8FromUtf16 helpers — use these |
