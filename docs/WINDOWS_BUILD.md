# Windows Build Runbook

How to build this fork of BlueBubbles on Windows (x64). Generated while scoping custom features.

> **Source of truth note:** The toolchain floor below comes from `pubspec.lock`, **not** `pubspec.yaml`.
> The pubspec's `environment: sdk: '>=3.1.3 <4.0.0'` line is stale — the resolved lockfile requires a much newer SDK.

## Toolchain requirements

| Tool | Required version | Notes |
|------|-----------------|-------|
| Flutter SDK | **≥ 3.41.0** | From `pubspec.lock` `sdks:` section. Run `flutter --version` to confirm. |
| Dart | **≥ 3.11.0 < 4.0.0** | Ships inside the matching Flutter release. |
| Visual Studio 2022 | **"Desktop development with C++"** workload | CMake uses MSVC-only flags (`/W4 /WX /EHsc`, `_HAS_EXCEPTIONS=0`). Needs the full C++ desktop workload incl. Windows 10/11 SDK + CMake — not standalone Build Tools alone. |
| CMake | ≥ 3.14 | Bundled with the VS C++ workload. |
| Git | recent | Required — several deps come from git forks (see below). Offline builds will fail at `pub get`. |

> **⚠️ Flutter must NOT live in a path with spaces.** Dart's native-assets hook runner invokes `dart.exe`
> unquoted; a space in the SDK path (e.g. the old `C:\Users\James Hazelton\dev\flutter`) makes cmd.exe parse
> `C:\Users\James` as the command and breaks both `dart run build_runner` and native-asset builds. The SDK now
> lives at `C:\src\flutter` for this reason. Keep it there.

Confirm readiness with:
```powershell
flutter doctor -v
```
The **Visual Studio** and **Windows** sections must be green.

### Verified local environment (2026-05-29)

This machine is **ready to build for Windows**:

| Component | Installed | vs. requirement |
|-----------|-----------|-----------------|
| Flutter | 3.44.0 stable (`C:\src\flutter`) | ✅ ≥ 3.41.0 |
| Dart | 3.12.0 | ✅ ≥ 3.11.0 |
| Visual Studio | Community 2022 17.14, Windows 10 SDK 10.0.26100.0 | ✅ C++ desktop toolchain green |
| Windows desktop device | available | ✅ |
| Git | `C:\Program Files\Git` | ✅ |
| Android SDK | **missing** | ❌ — only matters if we also target Android; irrelevant for Windows |

> **PATH:** `C:\src\flutter\bin` was added to the user PATH (replacing the old spaced path). New terminals get
> `flutter`/`dart` directly; already-open terminals need a restart to pick it up.

## Target / output

- **x64 only** (`windows-x64`). No ARM64 configuration exists.
- Binary: `bluebubbles_app.exe` (C++17, links `dwmapi.lib`).
- App version: `2.0.0+84` (2.0 rewrite branch).
- Release output path: `build\windows\x64\runner\Release\`.

## Pre-build gotchas

### 1. `.env` must exist or the build fails
`pubspec.yaml` declares `.env` as a bundled asset. It is **not** committed to the repo. Flutter errors on a
missing declared asset even though `lib/main.dart` loads it with `isOptional: true`.

- Create at least an **empty `.env`** at the repo root.
- The only key the code reads is `TENOR_API_KEY` (GIF search, `lib/.../text_field_icon_bar.dart`). Everything
  else works without it.

```
# .env (repo root)
TENOR_API_KEY=
```

### 2. ObjectBox codegen must run on a fresh checkout
After any `@Entity` change in `lib/database/io/` — and on first checkout — regenerate:
```powershell
dart run build_runner build --delete-conflicting-outputs
```
Output is `lib/generated/objectbox.g.dart` — never hand-edit it.

## Git-sourced dependencies (need network + git at `pub get`)

These are BlueBubbles forks / pins rather than pub.dev packages:

- `firebase_dart` (appsup-dart fork) — pure-Dart Firebase, so **no `google-services` native config needed on Windows**
- `flutter_map` (override → fleaflet commit)
- `permission_handler_windows` (BlueBubbles fork)
- `desktop_webview_auth`, `disable_battery_optimization`, `gesture_x_detector`, `local_notifier` (BB forks)

## Build commands

```powershell
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter build windows --release
```

## Packaging (for distributing a custom build)

- **MSIX** (`msix` package, configured in `pubspec.yaml` under `msix_config`):
  - Identity `23344BlueBubbles.BlueBubbles`, version `1.15.100.0`, `store: true`.
  - For a custom/sideload build, change `identity_name`, `publisher`, `publisher_display_name`, and set `store: false`.
  - Build: `dart run msix:create`
- **Inno Setup installer**: `windows/bluebubbles_installer_script.iss` (+ `CodeDependencies.iss`).

## Runtime requirement

BlueBubbles requires a Mac on the network running the **BlueBubbles Server** + an Apple ID. The desktop app is a
client only.
