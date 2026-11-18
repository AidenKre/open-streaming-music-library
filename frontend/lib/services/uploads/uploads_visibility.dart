import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the Uploads page is visible. The page drives it; the upload
/// manager polls the server's item states only while it is true.
abstract interface class UploadsVisibility {
  ValueListenable<bool> get visible;
  void setVisible(bool value);
}

class NotifierUploadsVisibility implements UploadsVisibility {
  final _visible = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get visible => _visible;

  @override
  void setVisible(bool value) => _visible.value = value;

  void dispose() => _visible.dispose();
}

/// Not visible until the page says so.
final uploadsVisibilityProvider = Provider<UploadsVisibility>((ref) {
  final visibility = NotifierUploadsVisibility();
  ref.onDispose(visibility.dispose);
  return visibility;
});
