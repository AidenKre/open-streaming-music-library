// The batch duplicate summary over the review snapshot (spec §7 Duplicate
// UX; SC-25 coverage). Model code: pure, nothing from ui/.
import 'package:frontend/models/dto/upload_dtos.dart';

class DuplicateSummary {
  const DuplicateSummary._({required this.line, required this.footnotes});

  factory DuplicateSummary.of(List<UploadItem> items) {
    if (items.isEmpty) {
      return const DuplicateSummary._(line: null, footnotes: []);
    }
    var library = 0, within = 0, other = 0, notChecked = 0, failed = 0;
    for (final item in items) {
      final check = item.duplicateCheck;
      if (check == null) {
        notChecked++;
        continue;
      }
      if (!check.isReadable || check.status != 'complete') {
        failed++;
        continue;
      }
      final subjects = [for (final m in check.matches) m.subject];
      if (subjects.any((s) => s is LibraryTrackSubject)) library++;
      final staged = subjects.whereType<StagedItemSubject>();
      if (staged.any((s) => s.batchUuid == item.batchUuid)) within++;
      if (staged.any((s) => s.batchUuid != item.batchUuid)) other++;
    }

    String plural(int n, String one, String many) => n == 1 ? one : many;
    final parts = <String>[
      if (library > 0)
        '$library of ${items.length} files may already be in your library',
      if (within > 0)
        plural(within, '1 is a duplicate within this upload',
            '$within are duplicates within this upload'),
      if (other > 0)
        plural(other, '1 matches a file in another upload',
            '$other match files in other uploads'),
      if (notChecked > 0)
        plural(notChecked, '1 file not checked for duplicates yet',
            '$notChecked files not checked for duplicates yet'),
      if (failed > 0)
        "the duplicate check couldn't run for $failed "
            '${failed == 1 ? 'file' : 'files'}',
    ];
    final String line;
    if (parts.isNotEmpty) {
      final joined = parts.join(' · ');
      final firstIsFailed = library + within + other + notChecked == 0;
      line = firstIsFailed
          ? '${joined[0].toUpperCase()}${joined.substring(1)}'
          : joined;
    } else if (items.every(
      (i) =>
          i.duplicateCheck?.noDuplicatesFound(
            layers: {DuplicateLayer.exact, DuplicateLayer.fingerprint},
          ) ??
          false,
    )) {
      line = 'No duplicates found';
    } else {
      line = 'No matches among what could be compared';
    }
    return DuplicateSummary._(line: line, footnotes: _footnotes(items));
  }

  static List<String> _footnotes(List<UploadItem> items) {
    var noTool = false;
    var pending = 0, failed = 0, notComparable = 0;
    var unknown = false;
    void count(int? n, void Function(int) take) {
      if (n == null) {
        unknown = true;
      } else {
        take(n);
      }
    }

    for (final item in items) {
      final check = item.duplicateCheck;
      if (check == null || !check.isReadable || check.status != 'complete') {
        continue;
      }
      count(check.exact.libraryPending, (n) => pending = _max(pending, n));
      count(check.exact.libraryFailed, (n) => failed = _max(failed, n));
      final fp = check.fingerprint;
      if (fp.subjectState == 'unavailable') {
        noTool = true;
        continue;
      }
      count(fp.libraryPending, (n) => pending = _max(pending, n));
      count(fp.libraryFailed, (n) => failed = _max(failed, n));
      count(
        fp.libraryNotComparable,
        (n) => notComparable = _max(notComparable, n),
      );
    }
    return [
      if (noTool) 'Only exact copies are detected on this server',
      if (pending > 0)
        pending == 1
            ? '1 library track not yet scanned'
            : '$pending library tracks not yet scanned',
      if (failed > 0)
        failed == 1
            ? '1 library track could not be checked'
            : '$failed library tracks could not be checked',
      if (notComparable > 0)
        notComparable == 1
            ? '1 library track is too short or quiet to compare by sound'
            : '$notComparable library tracks are too short or quiet to '
                  'compare by sound',
      if (unknown) 'Part of your library could not be compared',
    ];
  }

  static int _max(int a, int b) => a > b ? a : b;

  /// The summary line, or null for an empty snapshot.
  final String? line;

  /// What could not be compared, each once.
  final List<String> footnotes;
}
