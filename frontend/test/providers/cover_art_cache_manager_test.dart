import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';

class MockCacheManager extends Mock implements BaseCacheManager {}

class FakeFileInfo extends Fake implements FileInfo {
  FakeFileInfo(this._path) {
    final fs = MemoryFileSystem();
    _file = fs.file(_path)..createSync(recursive: true);
  }
  final String _path;
  late final File _file;

  @override
  File get file => _file;
}

void main() {
  late MockCacheManager mockCache;
  late CoverArtCacheManager manager;

  setUp(() {
    ApiClient.init('http://localhost:8000');
    mockCache = MockCacheManager();
    manager = CoverArtCacheManager(cache: mockCache);
  });

  group('resolveArtUri', () {
    test('returns null when hasAlbumArt is false', () async {
      final uri = await manager.resolveArtUri(
        hasAlbumArt: false,
        coverArtId: 5,
      );
      expect(uri, isNull);
      verifyNever(() => mockCache.getFileFromCache(any()));
    });

    test('returns null when coverArtId is null', () async {
      final uri = await manager.resolveArtUri(
        hasAlbumArt: true,
        coverArtId: null,
      );
      expect(uri, isNull);
      verifyNever(() => mockCache.getFileFromCache(any()));
    });

    test('returns file URI when image is cached', () async {
      when(() => mockCache.getFileFromCache(any()))
          .thenAnswer((_) async => FakeFileInfo('/tmp/cached_cover.jpg'));

      final uri = await manager.resolveArtUri(
        hasAlbumArt: true,
        coverArtId: 42,
      );

      expect(uri, Uri.file('/tmp/cached_cover.jpg'));
      verify(() => mockCache.getFileFromCache(
            'http://localhost:8000/cover_art/42',
          )).called(1);
    });

    test('returns network URL when image is not cached', () async {
      when(() => mockCache.getFileFromCache(any()))
          .thenAnswer((_) async => null);

      final uri = await manager.resolveArtUri(
        hasAlbumArt: true,
        coverArtId: 42,
      );

      expect(uri, Uri.parse('http://localhost:8000/cover_art/42'));
    });
  });

  group('imageProvider', () {
    test('returns CoverArtImageProvider with correct URL', () {
      final provider = manager.imageProvider(42);

      expect(provider, isA<CoverArtImageProvider>());
      expect((provider as CoverArtImageProvider).url,
          'http://localhost:8000/cover_art/42');
    });
  });

  group('prefetch', () {
    test('calls downloadFile for each cover art ID', () {
      when(() => mockCache.downloadFile(any()))
          .thenAnswer((_) async => FakeFileInfo('/tmp/cover.jpg'));

      manager.prefetch([1, 2, 3]);

      verify(() => mockCache.downloadFile('http://localhost:8000/cover_art/1'))
          .called(1);
      verify(() => mockCache.downloadFile('http://localhost:8000/cover_art/2'))
          .called(1);
      verify(() => mockCache.downloadFile('http://localhost:8000/cover_art/3'))
          .called(1);
    });

    test('does nothing for empty list', () {
      manager.prefetch([]);
      verifyNever(() => mockCache.downloadFile(any()));
    });
  });

  group('noop constructor', () {
    test('imageProvider returns NetworkImage', () {
      final noop = CoverArtCacheManager.noop();
      final provider = noop.imageProvider(42);
      expect(provider, isA<NetworkImage>());
    });

    test('resolveArtUri returns network URL without cache lookup', () async {
      final noop = CoverArtCacheManager.noop();
      final uri = await noop.resolveArtUri(
        hasAlbumArt: true,
        coverArtId: 42,
      );
      expect(uri, Uri.parse('http://localhost:8000/cover_art/42'));
    });

    test('prefetch is a no-op', () {
      final noop = CoverArtCacheManager.noop();
      // Should not throw
      noop.prefetch([1, 2, 3]);
    });
  });
}
