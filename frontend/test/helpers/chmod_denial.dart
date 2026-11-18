import 'dart:io';

/// Whether `chmod` really takes access away on this machine: a directory
/// made read-only refuses a new file, and a file made unreadable refuses a
/// read. False as root, on Windows, or where mode bits are not enforced
/// (other-issues row 62: a probe, not a user-id check).
final bool chmodDenies = _probe();

/// `skip:` for a test that needs [chmodDenies]: skipped, never passed, where
/// chmod does not deny.
Object get skipUnlessChmodDenies => chmodDenies
    ? false
    : 'chmod does not deny access here (root, Windows, or modes not '
        'enforced)';

bool _probe() {
  if (Platform.isWindows) return false;
  final dir = Directory.systemTemp.createTempSync('chmod_probe_');
  final file = File('${dir.path}/probe')..writeAsStringSync('x');
  try {
    Process.runSync('chmod', ['000', file.path]);
    Process.runSync('chmod', ['555', dir.path]);
    var writeRefused = false;
    try {
      File('${dir.path}/new').writeAsStringSync('x');
    } on FileSystemException {
      writeRefused = true;
    }
    var readRefused = false;
    try {
      file.readAsStringSync();
    } on FileSystemException {
      readRefused = true;
    }
    return writeRefused && readRefused;
  } finally {
    Process.runSync('chmod', ['-R', 'u+rwx', dir.path]);
    dir.deleteSync(recursive: true);
  }
}
