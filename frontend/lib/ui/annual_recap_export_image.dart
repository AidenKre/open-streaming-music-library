import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/ui/listening_stats/listening_stats_format.dart';

/// The recap's export image (spec §6): a fixed layout, rendered apart from
/// the viewport, so a short window or large text never crops it. It reads
/// only the [AnnualRecap] it is given.
///
/// Height budget (675): 24 padding + 56 header + 16 gap + 112 tiles
/// (2 rows of 52 + 8) + 20 gap + 212 lists (24 heading + 5 x 36 rows + 8)
/// + flexible spacer (>= 0) + 44 footer + 24 padding = 508 fixed.
class RecapExportImage extends StatelessWidget {
  const RecapExportImage({super.key, required this.recap});

  /// The layout's fixed logical size.
  static const Size logicalSize = Size(540, 675);

  /// Device pixels per logical pixel in the exported PNG.
  static const double pixelRatio = 2;

  final AnnualRecap recap;

  static const _ink = Color(0xFF1B1B1F);
  static const _muted = Color(0xFF5E5E66);
  static const _paper = Color(0xFFFFFFFF);

  static Text _text(
    String text, {
    required double size,
    FontWeight? weight,
    Color color = _ink,
  }) => Text(
    text,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: size, fontWeight: weight, color: color),
  );

  Widget _tile(String label, String value) => SizedBox(
    width: 156,
    height: 52,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: 16, child: _text(label, size: 12, color: _muted)),
        SizedBox(
          height: 30,
          child: _text(value, size: 22, weight: FontWeight.w600),
        ),
      ],
    ),
  );

  Widget _list(String title, List<(String, String?)> rows) => SizedBox(
    width: 156,
    height: 212,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 24,
          child: _text(title, size: 15, weight: FontWeight.w600),
        ),
        for (final (primary, secondary) in rows)
          SizedBox(
            height: 36,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 18, child: _text(primary, size: 13)),
                SizedBox(
                  height: 14,
                  child: secondary == null
                      ? null
                      : _text(secondary, size: 11, color: _muted),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final busiest = recap.busiestMonth;
    final media = MediaQuery.maybeOf(context) ?? const MediaQueryData();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: media.copyWith(textScaler: TextScaler.noScaling),
        child: Theme(
          data: ThemeData(
            brightness: Brightness.light,
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF3F51B5),
            ),
          ),
          // Fixed text style: nothing ambient (the dialog's) reaches the image.
          child: DefaultTextStyle(
            style: const TextStyle(
              color: _ink,
              fontSize: 14,
              height: 1.2,
              letterSpacing: 0,
              fontStyle: FontStyle.normal,
              fontWeight: FontWeight.normal,
              decoration: TextDecoration.none,
            ),
            child: SizedBox.fromSize(
              key: const ValueKey('recap.export'),
              size: logicalSize,
              child: ColoredBox(
                color: _paper,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 56,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 18,
                              child: _text(
                                recap.isYearSoFar
                                    ? '${recap.year} · Year so far · UTC'
                                    : '${recap.year} · UTC',
                                size: 13,
                                color: _muted,
                              ),
                            ),
                            SizedBox(
                              height: 38,
                              child: _text(
                                'Year in music',
                                size: 30,
                                weight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 112,
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            _tile(
                              'Listening time',
                              formatListeningTime(
                                recap.totals.listeningSeconds,
                              ),
                            ),
                            _tile(
                              'Qualified plays',
                              '${recap.totals.qualifiedPlays}',
                            ),
                            _tile(
                              'Unique tracks',
                              '${recap.totals.uniqueTracks}',
                            ),
                            _tile('Active days', '${recap.totals.activeDays}'),
                            _tile(
                              'Deleted or unknown tracks',
                              formatListeningTime(
                                recap.unavailable.listeningSeconds,
                              ),
                            ),
                            if (busiest != null)
                              _tile('Busiest month', recapMonthName(busiest)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 212,
                        child: recap.isEmpty
                            ? _text(
                                'No listening in ${recap.year}',
                                size: 15,
                                color: _muted,
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  _list('Top tracks', [
                                    for (final e in recap.topTracks)
                                      (
                                        e.entity.title ?? 'Unknown title',
                                        e.entity.artist,
                                      ),
                                  ]),
                                  _list('Top artists', [
                                    for (final e in recap.topArtists)
                                      (e.entity.name, null),
                                  ]),
                                  _list('Top albums', [
                                    for (final e in recap.topAlbums)
                                      (
                                        e.entity.name ?? 'Unknown album',
                                        e.entity.artist,
                                      ),
                                  ]),
                                ],
                              ),
                      ),
                      const Spacer(),
                      SizedBox(
                        key: const ValueKey('recap.export.footer'),
                        height: 44,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 22,
                              child: _text(
                                'Generated ${formatUtcInstant(recap.generatedAtUtcMs)}. '
                                'All times UTC.',
                                size: 12,
                                color: _muted,
                              ),
                            ),
                            SizedBox(
                              height: 22,
                              child: _text(
                                'From your listening history on all your devices, '
                                'as synced to this one.',
                                size: 12,
                                color: _muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [RecapExportImage] scaled to the space available, inside the
/// repaint boundary [boundaryKey] that [captureRecapPng] reads.
class RecapExportFrame extends StatelessWidget {
  const RecapExportFrame({
    super.key,
    required this.recap,
    required this.boundaryKey,
  });

  final AnnualRecap recap;
  final GlobalKey boundaryKey;

  @override
  Widget build(BuildContext context) => Center(
    child: FittedBox(
      fit: BoxFit.contain,
      child: RepaintBoundary(
        key: boundaryKey,
        child: RecapExportImage(recap: recap),
      ),
    ),
  );
}

/// The PNG bytes of the export inside [boundaryKey]'s repaint boundary.
Future<Uint8List> captureRecapPng(GlobalKey boundaryKey) async {
  final boundary = boundaryKey.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) {
    throw StateError('The recap export is not on screen.');
  }
  final image = await boundary.toImage(pixelRatio: RecapExportImage.pixelRatio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('The recap image could not be encoded.');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}
