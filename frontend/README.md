# OSML app

The Flutter app for OSML: it signs in to your OSML server, plays your library
from it and keeps downloaded tracks for offline listening. It needs a running
server; set that up first (see [`../backend/README.md`](../backend/README.md)).

## Prerequisites

- Flutter 3.44 or later (Dart 3.12 or later): `pubspec.lock` needs at least
  these versions, even though `pubspec.yaml` allows an older Dart.
- The toolchain for the platform you build for (Xcode for iOS and macOS, the
  Android SDK for Android); `flutter doctor` reports what is missing.

## Setup

Run these from this `frontend/` folder:

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

The second command generates the database code
(`lib/database/database.g.dart`). That file is not in git, so the app does not
compile without this step. Run it again after pulling changes under
`lib/database/`.

## Run

```sh
flutter devices          # lists the devices and their ids
flutter run -d macos     # or -d <device id>
```

The project has folders for Android, iOS, macOS, Linux, Windows and web, but
so far the app has been run on macOS only. Linux and Windows builds are not
expected to play audio: the playback plugins the app uses (`just_audio`,
`audio_service`) have no Linux or Windows implementation in this project. The
web build is not supported: the app's database uses `dart:io` and drift's
native SQLite.

### iOS and macOS signing

- **iOS:** the project names its owner's development team and the bundle
  identifier `com.aidenkre.omsl`. Open `ios/Runner.xcworkspace` in Xcode,
  select the Runner target, and under Signing & Capabilities choose your own
  team and change the bundle identifier to one of yours.
- **macOS:** the project signs ad-hoc and names no team. To use the macOS
  Keychain, see "Platform notes" below.

## Connecting to a server

The first screen asks for the **Server URL**. Enter it with the scheme and
port, for example `http://192.168.1.20:8000` (the server's address on your
network and the port it was started with), and press **Connect**. The app
checks that a compatible OSML server answers there, then shows **Log in**, for
example with the master admin set up on the server. **Create account** works
only while the server allows signup (`OSML_SIGNUP_ENABLED`) and has room for
another user (`OSML_MAX_USERS`).

The app accepts `http://` and `https://` addresses. Android
(`usesCleartextTraffic`), iOS and macOS (`NSAllowsArbitraryLoads`) are set to
allow plain `http://`, which is not encrypted on the network.

## Local database

The app keeps its data in `database.db` in its application-support folder.
Its schema is at version 1: a database file stamped with any other version
(for example from an earlier build of the app) is refused when it opens, and
nothing upgrades it.

## Platform notes

- **Linux** (if you try a Linux build): the app stores your sign-in in the
  system keyring through `flutter_secure_storage`, so building it needs the
  libsecret development package (`libsecret-1-dev` on Debian/Ubuntu), and
  signing in uses a running Secret Service (for example GNOME Keyring). When
  no Secret Service is installed at all, the app uses an owner-only file in
  its app-support folder instead (also when saving to the keyring fails) and
  says so under Settings → Sync & storage. Any other keyring problem when
  reading (for example a locked keyring or a timeout) is treated as
  temporary: the app shows "Your sign-in could not be read." with **Try
  again** and **Log in again** instead of signing you out. The app recognises
  a missing Secret Service by the D-Bus error
  `org.freedesktop.DBus.Error.ServiceUnknown` naming
  `org.freedesktop.secrets`, or by the sentence dbus-daemon gives for it; any
  message that carries neither (for example another D-Bus implementation's
  wording with the error name stripped) is treated as such a temporary
  problem.
- **iOS:** the sign-in goes into the Keychain (`keychain-access-groups`
  entitlement in `ios/Runner/Runner.entitlements`).
- **macOS:** the project carries no keychain entitlement, so the app stores
  the sign-in in an owner-only fallback file in its app-support folder (inside
  the sandbox container) and says so under Settings → Sync & storage.
  - To turn the macOS Keychain on, set a development team for the Runner
    target in Xcode (Signing & Capabilities) and add the entitlement back to
    both `macos/Runner/DebugProfile.entitlements` and
    `macos/Runner/Release.entitlements`, for example
    `<key>keychain-access-groups</key><array><string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string></array>`.
  - `test/architecture/macos_signing_test.dart` rejects that entitlement
    while the project has no development team.

## Tests

```sh
flutter test --timeout 15s
```

This runs every `*_test.dart` file as its own suite, so each file is isolated
and timed on its own. It is the reference command.

### Fast test command

Each file in the default command pays its own test-process start and compile,
which dominates for small files. For faster feedback there is an optional
aggregated command. A generator groups all test files into N shard files under
`test_shards/` (gitignored, outside `test/`, not named `*_test.dart`, so
`flutter test` never discovers them). Each shard imports its test files and
runs each one's `main` inside `group('test/<path>', ...)`, so test names gain
the file path as a prefix.

```
dart run tool/gen_test_shards.dart --shards 4 && flutter test --concurrency=4 --timeout 15s test_shards/shard_*.dart
```

If `test_shards/excluded.txt` is non-empty, those files must also run per-file, so the
command still covers every test (the guard matters: `flutter test` with no file arguments would run the whole per-file suite):

```
[ -s test_shards/excluded.txt ] && flutter test --timeout 15s $(cat test_shards/excluded.txt)
```

Notes:

- The generator discovers every test file, assigns each to exactly one shard
  (deterministic; balanced by file size, or by `--timings <file.csv>`), and exits
  non-zero if a file is unassigned or assigned twice. Exclusions are listed, with reasons,
  in the `excluded` map at the top of `tool/gen_test_shards.dart`. The `--timings` file
  (a CSV with the columns `file` and `sum_test_s`, described at the top of the generator)
  is not produced by anything in this repository; without it the split is by file size.
- Limits: tests in a shard share one isolate, so global state can leak between files
  (the per-file command hides this); one compile error fails the whole shard (use the
  per-file command to diagnose); per-file timing comes only from the default command.
