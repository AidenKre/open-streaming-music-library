// The SC-01 binding errors: value types, shared by the repository, the API
// clients and the runners.

/// A fenced write's captured `local_binding_id` no longer matches the
/// binding row (a reset deleted it, or a re-bind replaced it). The write did
/// not happen.
class BindingFencedException implements Exception {
  BindingFencedException(this.token);
  final String token;

  @override
  String toString() => 'BindingFencedException($token)';
}

/// SC-01 rule 6: a server response was stamped by another instance than the
/// bound one. The page it carried was not committed, or the write response
/// was treated as not delivered. Its text names neither id (they are not for
/// user-visible logs).
class ServerInstanceChangedException implements Exception {
  ServerInstanceChangedException({
    required this.boundInstanceId,
    required this.servedBy,
  });
  final String boundInstanceId;
  final String servedBy;

  @override
  String toString() =>
      'ServerInstanceChangedException: a different server answered; '
      'the response was not applied';
}
