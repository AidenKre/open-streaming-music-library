/// Whether the scope's session token may go with a request (sign-off
/// OPEN-M-11, 2026-11-17). The binding gate implements it; the token client
/// asks it per request.
abstract interface class TokenPermit {
  /// True only when the token may go to [url] right now. Synchronous, so
  /// nothing can change between the answer and the send.
  bool allowsTokenTo(Uri url);

  /// Completes once no verdict is pending for the current connection, or
  /// after a bound. Never throws.
  Future<void> verdictSettled();
}
