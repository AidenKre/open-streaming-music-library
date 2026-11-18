/// `m:ss`, `h:mm:ss` from one hour, or `d:hh:mm:ss` from one day. Whole
/// seconds are truncated, not rounded.
String formatTrackDuration(double seconds) {
  final totalSeconds = seconds.truncate();
  final s = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = (totalSeconds ~/ 3600) % 24;
  final days = totalSeconds ~/ 86400;

  final ss = s.toString().padLeft(2, '0');
  final mm = minutes.toString().padLeft(2, '0');
  final hh = hours.toString().padLeft(2, '0');
  if (days > 0) return '$days:$hh:$mm:$ss';
  if (hours > 0) return '$hours:$mm:$ss';
  return '$minutes:$ss';
}
