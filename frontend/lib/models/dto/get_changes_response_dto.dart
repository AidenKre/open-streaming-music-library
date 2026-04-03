import 'package:frontend/models/dto/change_entry_dto.dart';

class GetChangesResponseDto {
  final List<ChangeEntryDto> changes;

  /// Revision to request next (the last entry's revision) when more remain;
  /// null once the client has caught up.
  final int? nextCursor;

  /// Current server revision at query time — informational only. The client
  /// persists the last applied entry's revision, not this.
  final int latestRevision;

  const GetChangesResponseDto({
    required this.changes,
    required this.latestRevision,
    this.nextCursor,
  });

  factory GetChangesResponseDto.fromJson(Map<String, dynamic> json) {
    return GetChangesResponseDto(
      changes: (json['changes'] as List<dynamic>)
          .map((e) => ChangeEntryDto.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: (json['nextCursor'] as num?)?.toInt(),
      latestRevision: (json['latestRevision'] as num).toInt(),
    );
  }
}
