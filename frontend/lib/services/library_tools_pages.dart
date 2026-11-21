// Phase 8 spec §6: what the library-tools pages (Possible duplicates and
// Deletion history) share. Model code: nothing from ui/.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/gated_send.dart';
import 'package:frontend/services/session_service.dart';

/// Why a library-tools page can't read from the server now.
enum LibraryToolsUnreachable {
  /// Offline, the server unreachable, or the connection not verified yet.
  needsConnection,

  /// A different server answers at this address.
  differentServer,

  /// Signed out, or no session for this binding.
  signedOut,
}

/// The reason a page says: the session's block wins (it is what the banner
/// shows); then the reason the last read was refused; else
/// [LibraryToolsUnreachable.needsConnection].
LibraryToolsUnreachable libraryToolsUnreachable({
  required ServerBlockedReason blocked,
  BindingRefusal? refusal,
}) {
  switch (blocked) {
    case ServerBlockedReason.differentServer:
      return LibraryToolsUnreachable.differentServer;
    case ServerBlockedReason.signedOut:
      return LibraryToolsUnreachable.signedOut;
    case ServerBlockedReason.none:
      break;
  }
  return switch (refusal) {
    BindingRefusal.differentServer => LibraryToolsUnreachable.differentServer,
    BindingRefusal.noSession => LibraryToolsUnreachable.signedOut,
    BindingRefusal.notYet || null => LibraryToolsUnreachable.needsConnection,
  };
}

/// Reading again can help only while the session's server is not blocked: a
/// different server or a sign-out is cleared by the banner's Reset,
/// Disconnect or Log in, never by a Retry. A refused read alone keeps its
/// Retry (the session may not have caught up yet).
bool libraryToolsRetryHelps(ServerBlockedReason blocked) =>
    blocked == ServerBlockedReason.none;

/// What Possible duplicates says for [reason].
String duplicatesUnreachableText(LibraryToolsUnreachable reason) =>
    switch (reason) {
      LibraryToolsUnreachable.needsConnection =>
        'Possible duplicates needs a connection',
      LibraryToolsUnreachable.differentServer =>
        'Possible duplicates is not available: a different server answers '
            'at this address.',
      LibraryToolsUnreachable.signedOut =>
        'Possible duplicates is not available: you are signed out.',
    };

/// What Deletion history says for [reason].
String deletionHistoryUnreachableText(LibraryToolsUnreachable reason) =>
    switch (reason) {
      LibraryToolsUnreachable.needsConnection =>
        'Deletion history needs a connection.',
      LibraryToolsUnreachable.differentServer =>
        'Deletion history is not available: a different server answers at '
            'this address.',
      LibraryToolsUnreachable.signedOut =>
        'Deletion history is not available: you are signed out.',
    };

/// The session's server block, live. A different server or a 401 sign-out
/// turns the app offline, so a page on its offline path needs the
/// session's reason to say why.
final libraryToolsServerBlockedProvider = Provider<ServerBlockedReason>((ref) {
  final listenable = ref.watch(sessionServiceProvider).serverBlocked;
  void onChange() => ref.invalidateSelf();
  listenable.addListener(onChange);
  ref.onDispose(() => listenable.removeListener(onChange));
  return listenable.value;
});

/// One pending wait (no polling) for the library-tools binding to verify
/// again, after a page read failed fast as not connected. [arm] while a
/// wait is pending does nothing; when it ends [onVerified] runs; a wait
/// that ends in an error (the gate closed) runs nothing, and the next
/// [arm] waits again.
class ReloadWhenVerified {
  ReloadWhenVerified({
    required Future<void> Function() whenVerified,
    required void Function() onVerified,
  }) : _whenVerified = whenVerified,
       _onVerified = onVerified;

  final Future<void> Function() _whenVerified;
  final void Function() _onVerified;
  bool _awaiting = false;

  void arm() {
    if (_awaiting) return;
    _awaiting = true;
    _whenVerified().then(
      (_) {
        _awaiting = false;
        _onVerified();
      },
      onError: (Object _) {
        _awaiting = false;
      },
    );
  }
}
