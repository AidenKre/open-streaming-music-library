import 'package:flutter/foundation.dart';
import 'package:frontend/ui/collection_detail_controller.dart';

/// A settable collection detail controller for widget tests; records the
/// inputs it receives.
class FakeCollectionDetailControls extends ChangeNotifier
    implements CollectionDetailControls {
  final calls = <String>[];
  bool _busy = false;
  String? _message;
  bool _canRetry = false;

  @override
  bool get busy => _busy;

  @override
  String? get message => _message;

  @override
  bool get canRetry => _canRetry;

  void set({bool? busy, String? message, bool? canRetry}) {
    _busy = busy ?? _busy;
    _message = message;
    _canRetry = canRetry ?? (message != null);
    notifyListeners();
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> shuffle() async => calls.add('shuffle');

  @override
  Future<void> retry() async => calls.add('retry');
}
