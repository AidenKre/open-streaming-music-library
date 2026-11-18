// SC-03 typed feature blocks of `/app/info` (Phase 7B.1a, D23).
//
// Each block is independent: a malformed one is null (unsupported) and never
// affects another or throws. Unknown blocks and fields are ignored. `auth`
// and `server` stay out of here (the pre-session identity probe reads them).

/// A positive integer `version` (a Dart `int`: 1.0, '1' and bools are not).
int? _version(Object? block) {
  if (block is! Map) return null;
  final v = block['version'];
  return v is int && v >= 1 ? v : null;
}

/// A limit kept only when it is an `int` >= 0; otherwise unknown (null).
int? _limit(Map limits, String key) {
  final v = limits[key];
  return v is int && v >= 0 ? v : null;
}

/// `history: {version}` (Phase 5): history sync.
class HistoryFeature {
  const HistoryFeature({required this.version});
  final int version;

  static HistoryFeature? fromJson(Object? block) {
    final v = _version(block);
    return v == null ? null : HistoryFeature(version: v);
  }

  Map<String, dynamic> toJson() => {'version': version};
}

/// The effective upload limits the server advertises. Each is null when
/// unknown (missing or malformed): never 0, never unlimited.
class UploadLimits {
  const UploadLimits({
    this.maxFilesPerBatch,
    this.maxFileBytes,
    this.maxBatchBytes,
    this.maxExpandedBytesPerBatch,
    this.maxExpandedMemberBytes,
    this.maxAudioItemsPerBatch,
    this.maxArchiveMembers,
    this.maxCompressionRatio,
    this.receives,
    this.stagedQuotaBytes,
    this.receivesPerUser,
    this.userStagedQuotaBytes,
  });

  factory UploadLimits.fromJson(Map limits) => UploadLimits(
    maxFilesPerBatch: _limit(limits, 'max_files_per_batch'),
    maxFileBytes: _limit(limits, 'max_file_bytes'),
    maxBatchBytes: _limit(limits, 'max_batch_bytes'),
    maxExpandedBytesPerBatch: _limit(limits, 'max_expanded_bytes_per_batch'),
    maxExpandedMemberBytes: _limit(limits, 'max_expanded_member_bytes'),
    maxAudioItemsPerBatch: _limit(limits, 'max_audio_items_per_batch'),
    maxArchiveMembers: _limit(limits, 'max_archive_members'),
    maxCompressionRatio: _limit(limits, 'max_compression_ratio'),
    receives: _limit(limits, 'receives'),
    stagedQuotaBytes: _limit(limits, 'staged_quota_bytes'),
    receivesPerUser: _limit(limits, 'receives_per_user'),
    userStagedQuotaBytes: _limit(limits, 'user_staged_quota_bytes'),
  );

  // Unknown (null) for every limit below: no client-side pre-check; the
  // server's answer decides. Exception: `receives` / `receivesPerUser`.

  final int? maxFilesPerBatch;
  final int? maxFileBytes;
  final int? maxBatchBytes;
  final int? maxExpandedBytesPerBatch;
  final int? maxExpandedMemberBytes;
  final int? maxAudioItemsPerBatch;
  final int? maxArchiveMembers;
  final int? maxCompressionRatio;

  /// Unknown: the upload runner (7B.1d) runs one transfer at a time (the
  /// conservative bound), never 0 and never unlimited.
  final int? receives;
  final int? stagedQuotaBytes;

  /// Unknown: as [receives], one transfer at a time.
  final int? receivesPerUser;
  final int? userStagedQuotaBytes;

  /// Wire shape; unknown limits are omitted.
  Map<String, dynamic> toJson() => {
    if (maxFilesPerBatch != null) 'max_files_per_batch': maxFilesPerBatch,
    if (maxFileBytes != null) 'max_file_bytes': maxFileBytes,
    if (maxBatchBytes != null) 'max_batch_bytes': maxBatchBytes,
    if (maxExpandedBytesPerBatch != null)
      'max_expanded_bytes_per_batch': maxExpandedBytesPerBatch,
    if (maxExpandedMemberBytes != null)
      'max_expanded_member_bytes': maxExpandedMemberBytes,
    if (maxAudioItemsPerBatch != null)
      'max_audio_items_per_batch': maxAudioItemsPerBatch,
    if (maxArchiveMembers != null) 'max_archive_members': maxArchiveMembers,
    if (maxCompressionRatio != null)
      'max_compression_ratio': maxCompressionRatio,
    if (receives != null) 'receives': receives,
    if (stagedQuotaBytes != null) 'staged_quota_bytes': stagedQuotaBytes,
    if (receivesPerUser != null) 'receives_per_user': receivesPerUser,
    if (userStagedQuotaBytes != null)
      'user_staged_quota_bytes': userStagedQuotaBytes,
  };
}

/// `uploads: {version, limits}` (Phase 7).
class UploadsFeature {
  const UploadsFeature({required this.version, this.limits = const UploadLimits()});
  final int version;
  final UploadLimits limits;

  static UploadsFeature? fromJson(Object? block) {
    final v = _version(block);
    final limits = block is Map ? block['limits'] : null;
    if (v == null || limits is! Map) return null;
    return UploadsFeature(version: v, limits: UploadLimits.fromJson(limits));
  }

  Map<String, dynamic> toJson() => {'version': version, 'limits': limits.toJson()};
}

/// Every feature block this client knows; null = unsupported.
class FeatureBlocks {
  const FeatureBlocks({this.history, this.uploads});

  factory FeatureBlocks.fromJson(Map<String, dynamic> root) => FeatureBlocks(
    history: HistoryFeature.fromJson(root['history']),
    uploads: UploadsFeature.fromJson(root['uploads']),
  );

  final HistoryFeature? history;
  final UploadsFeature? uploads;

  Map<String, dynamic> toJson() => {
    if (history != null) 'history': history!.toJson(),
    if (uploads != null) 'uploads': uploads!.toJson(),
  };
}
