import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/providers.dart';

/// The source codec of one track in the local catalog (null when unknown or
/// not synced). A single-track read, not a membership query; injected into
/// the preview's URI builder (7-R1-25) so the playback model does no I/O.
final trackSourceCodecLookupProvider =
    Provider<Future<String?> Function(String trackUuid)>((ref) =>
        (uuid) async =>
            (await ref.read(browseRepositoryProvider).getTrack(uuid))?.codec);
