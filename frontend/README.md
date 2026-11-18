# frontend

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Fast test command

The default `flutter test` is unchanged and remains the reference. It runs every
`*_test.dart` file as its own suite, so each file is isolated and timed on its own.
Each file pays its own test-process start and compile, which dominates for small files.

For faster feedback there is an optional aggregated command. A generator groups all
test files into N shard files under `test_shards/` (gitignored, outside `test/`, not named
`*_test.dart`, so `flutter test` never discovers them). Each shard imports its test files
and runs each one's `main` inside `group('test/<path>', ...)`, so test names gain the
file path as a prefix.

```
dart run tool/gen_test_shards.dart --shards 4 && flutter test --concurrency=4 --timeout 15s test_shards/shard_*.dart
```

If `test_shards/excluded.txt` is non-empty, those files must also run per-file, so the
command still covers every test (the guard matters: `flutter test` with no file arguments would run the whole per-file suite):

```
[ -s test_shards/excluded.txt ] && flutter test --timeout 15s $(cat test_shards/excluded.txt)
```

Notes:

- The generator discovers every test file, assigns each to exactly one shard
  (deterministic; balanced by file size, or by `--timings <baseline files.csv>`), and exits
  non-zero if a file is unassigned or assigned twice. Exclusions are listed, with reasons,
  in the `excluded` map at the top of `tool/gen_test_shards.dart`.
- Limits: tests in a shard share one isolate, so global state can leak between files
  (the per-file command hides this); one compile error fails the whole shard (use the
  per-file command to diagnose); per-file timing comes only from the default command.
