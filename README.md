# open-streaming-music-library

The goal of this repo is to create a comprehensive solution for anyone to set up a self hosted music streaming service for themself. The backend should be lightweight, running on users old hardware (e.g an old laptop). The backend should be easy to set up, and should not require much hassle. The backend should be easy to configure (and extremely configurable), there should not be much confusion about how to setup the backend to the users liking.

The frontend should be easy to use, and should be availiable on IOS, Android as well as MacOS, Windows, Linux and ChromeOS. Additionally, it should be accessable via the web. The frontend should mostly act as a music player, but also be able to configure runtime settings for the backend server.

The whole ecosystem should be easy to use for non power users, and also allow for power users to "fine-tune" everything to their liking. However, the priority is the non power users. This is to hopefully let more people enjoy AND own their music, rather than just streaming from a big streaming service.

Evidently, this repo is a huge WIP... with lofty goals. As such the scope has been narrowed significantly, and some compromises have been made. We are putting ease of use first.


## Building the app

- **Linux:** the app stores your sign-in in the system keyring through `flutter_secure_storage`, so building it needs the libsecret development package (`libsecret-1-dev` on Debian/Ubuntu) and a running Secret Service (for example GNOME Keyring). When no Secret Service is installed at all, the app uses an owner-only file in its app-support folder instead (also when saving to the keyring fails) and says so under Settings → Sync & storage. Any other keyring problem when reading (for example a locked keyring or a timeout) is treated as temporary: the app shows "Your sign-in could not be read." with **Try again** and **Log in again** instead of signing you out.
- **iOS:** the sign-in goes into the Keychain (`keychain-access-groups` entitlement in `ios/Runner/Runner.entitlements`; iOS builds are team-signed).
- **macOS:** the project signs ad-hoc and carries no keychain entitlement, so the app stores the sign-in in an owner-only fallback file in its app-support folder (inside the sandbox container) and says so under Settings → Sync & storage.
  - To turn the macOS Keychain on for a team-signed build, set a development team for the Runner target in Xcode (Signing & Capabilities) and add the entitlement back to both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`, for example `<key>keychain-access-groups</key><array><string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string></array>`.
  - `test/architecture/macos_signing_test.dart` rejects that entitlement while the project has no development team.
- **Server address:** on Android, iOS and macOS the app accepts an `http://` server address as well as `https://`, and an `http://` connection is not encrypted on the network.
