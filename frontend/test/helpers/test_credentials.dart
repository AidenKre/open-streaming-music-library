import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/services/credential_store.dart';

import 'fake_secure_backend.dart';

/// A signed-in session for tests whose work runs only with stored
/// credentials (`hasSessionProvider`, Phase M §7.2).
const testCredentials = Credentials(
  token: 'test-api-token',
  mediaToken: 'test-media-token',
  userId: 1,
  username: 'tester',
);

/// Seeds a signed-in session: credentials and a session URL (a session
/// needs both, `hasSessionProvider`).
final signedInOverrides = <Override>[
  credentialsProvider.overrideWithValue(testCredentials),
  sessionUrlProvider.overrideWithValue('http://localhost:8000'),
];

/// The process-wide credential store for widget tests that render the
/// Sync & storage diagnostics: an in-memory secure store (never the real
/// keychain) that holds nothing; no file is written.
Override credentialStoreTestOverride() => credentialStoreProvider.overrideWithValue(
      CredentialStore(
        secure: FakeSecureBackend(),
        directory: Directory('${Directory.systemTemp.path}/osml-no-credentials'),
      ),
    );
