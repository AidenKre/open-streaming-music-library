/// Why the session is blocked (Phase M 7.7): network work waits and the
/// app behaves as offline.
enum ServerBlockedReason { none, differentServer, signedOut }
