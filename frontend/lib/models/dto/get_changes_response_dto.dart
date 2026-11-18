import 'package:frontend/models/dto/change_entry_dto.dart';
import 'package:frontend/models/dto/json_fields.dart';

class GetChangesResponseDto {
  final List<ChangeEntryDto> changes;

  /// Revision to request next (the last entry's revision) when more remain;
  /// null once the client has caught up.
  final int? nextCursor;

  /// Current server revision at query time — informational only. The client
  /// persists the last applied entry's revision, not this.
  final int latestRevision;

  /// The server instance that served this page (SC-01 rule 6, from the
  /// response's `X-Server-Instance-Id`, not the body); null without a stamp.
  final String? servedBy;

  const GetChangesResponseDto({
    required this.changes,
    required this.latestRevision,
    this.nextCursor,
    this.servedBy,
  });

  /// Typed reads: a missing or malformed field is a [FormatException].
  factory GetChangesResponseDto.fromJson(
    Map<String, dynamic> json, {
    String? servedBy,
  }) {
    return GetChangesResponseDto(
      changes: [
        for (final e in jsonList(json, 'changes'))
          ChangeEntryDto.fromJson(jsonObject(e, 'change')),
      ],
      nextCursor: jsonWholeIntOrNull(json, 'nextCursor'),
      latestRevision: jsonWholeInt(json, 'latestRevision'),
      servedBy: servedBy,
    );
  }
}
