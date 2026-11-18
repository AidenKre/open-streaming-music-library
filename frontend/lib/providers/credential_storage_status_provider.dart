import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/credential_store.dart';

/// What the diagnostics row observes: where the sign-in is stored. Read-only;
/// views never touch the store.
final credentialStorageStatusProvider =
    Provider<ValueListenable<CredentialStorageStatus>>(
      (ref) => ref.watch(credentialStoreProvider).status,
    );
