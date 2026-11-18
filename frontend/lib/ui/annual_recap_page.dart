import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/ui/annual_recap_controller.dart';
import 'package:frontend/ui/annual_recap_export_image.dart';
import 'package:frontend/ui/listening_stats/listening_stats_format.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';

/// Year in music (spec §6): one UTC year's recap snapshot, reached from
/// Listening stats.
class AnnualRecapPage extends ConsumerStatefulWidget {
  const AnnualRecapPage({super.key});

  @override
  ConsumerState<AnnualRecapPage> createState() => _AnnualRecapPageState();
}

class _AnnualRecapPageState extends ConsumerState<AnnualRecapPage> {
  late final AnnualRecapControls _controls;

  @override
  void initState() {
    super.initState();
    _controls = ref.read(annualRecapControllerFactoryProvider)();
  }

  @override
  void dispose() {
    _controls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Year in music'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _controls.refresh,
          ),
          ListenableBuilder(
            listenable: _controls,
            builder: (context, _) => IconButton(
              key: const ValueKey('recap.export.open'),
              tooltip: 'Export',
              icon: const Icon(Icons.ios_share),
              onPressed: _controls.recap == null
                  ? null
                  : () => _openPreview(context),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controls,
        builder: (context, _) => ListView(
          padding: ShellChromeInsets.padEnd(
            context,
            const EdgeInsets.all(16),
          ),
          children: _children(context),
        ),
      ),
    );
  }

  Future<void> _openPreview(BuildContext context) {
    if (_controls.recap == null) return Future.value();
    final messenger = ScaffoldMessenger.of(context);
    // Fresh per dialog: one still leaving never shares it with a new one.
    final boundaryKey = GlobalKey();
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: _controls,
        builder: (context, _) {
          final recap = _controls.recap;
          final busy = _controls.exporting || recap == null;
          final canSave = _controls.canSave;
          final canShare = _controls.canShare;
          return AlertDialog(
            title: const Text('Export Year in music'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 360,
                    height: 450,
                    child: recap == null
                        ? const Center(child: CircularProgressIndicator())
                        : RecapExportFrame(
                            recap: recap,
                            boundaryKey: boundaryKey,
                          ),
                  ),
                  if (!canSave)
                    const Text('Saving files is not available on this device'),
                  if (!canShare)
                    const Text(
                      'Sharing files is not available on this device',
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
              TextButton(
                key: const ValueKey('recap.export.save_json'),
                onPressed: canSave && !busy
                    ? () => _run(messenger, _controls.saveJson)
                    : null,
                child: const Text('Save JSON'),
              ),
              TextButton(
                key: const ValueKey('recap.export.save_png'),
                onPressed: canSave && !busy
                    ? () => _runPng(
                        messenger,
                        boundaryKey,
                        (png) => _controls.savePng(png),
                      )
                    : null,
                child: const Text('Save image'),
              ),
              Builder(
                builder: (buttonContext) => FilledButton(
                  key: const ValueKey('recap.export.share_png'),
                  onPressed: canShare && !busy
                      ? () {
                          final box =
                              buttonContext.findRenderObject() as RenderBox;
                          final origin =
                              box.localToGlobal(Offset.zero) & box.size;
                          _runPng(
                            messenger,
                            boundaryKey,
                            (png) => _controls.sharePng(png, origin: origin),
                          );
                        }
                      : null,
                  child: const Text('Share image'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _runPng(
    ScaffoldMessengerState messenger,
    GlobalKey boundaryKey,
    Future<String?> Function(Uint8List png) export,
  ) async {
    final Uint8List png;
    try {
      png = await captureRecapPng(boundaryKey);
    } catch (_) {
      if (mounted) _say(messenger, 'Could not render the image');
      return;
    }
    await _run(messenger, () => export(png));
  }

  Future<void> _run(
    ScaffoldMessengerState messenger,
    Future<String?> Function() export,
  ) async {
    final answer = await export();
    if (mounted && answer != null) _say(messenger, answer);
  }

  void _say(ScaffoldMessengerState messenger, String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

  List<Widget> _children(BuildContext context) {
    final recap = _controls.recap;
    return [
      _yearPicker(),
      if (_controls.loading)
        const Center(child: CircularProgressIndicator())
      else if (_controls.failed) ...[
        const Text('Could not load your Year in music'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _controls.retry,
            child: const Text('Retry'),
          ),
        ),
      ] else if (recap != null)
        ..._recapBody(context, recap),
    ];
  }

  Widget _yearPicker() {
    final year = _controls.year;
    if (year == null) return const SizedBox.shrink();
    final years = _controls.years;
    if (!years.contains(year)) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: DropdownButton<int>(
        key: const ValueKey('recap.year'),
        value: year,
        items: [
          for (final y in years)
            DropdownMenuItem(value: y, child: Text('$y')),
        ],
        onChanged: (y) {
          if (y != null) _controls.selectYear(y);
        },
      ),
    );
  }

  List<Widget> _recapBody(BuildContext context, AnnualRecap recap) {
    final theme = Theme.of(context).textTheme;
    final empty = recap.isEmpty;
    final busiest = recap.busiestMonth;
    return [
      Text(
        recap.isYearSoFar
            ? '${recap.year} · Year so far · UTC'
            : '${recap.year} · UTC',
        style: theme.titleLarge,
      ),
      if (empty) Text('No listening in ${recap.year}'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          _tile(
            'recap.listening_time',
            'Listening time',
            formatListeningTime(recap.totals.listeningSeconds),
          ),
          _tile(
            'recap.qualified_plays',
            'Qualified plays',
            '${recap.totals.qualifiedPlays}',
          ),
          _tile(
            'recap.unique_tracks',
            'Unique tracks',
            '${recap.totals.uniqueTracks}',
          ),
          _tile('recap.active_days', 'Active days', '${recap.totals.activeDays}'),
          _tile(
            'recap.unavailable',
            'Unavailable history',
            formatListeningTime(recap.unavailable.listeningSeconds),
          ),
          if (busiest != null)
            _tile('recap.busiest_month', 'Busiest month', recapMonthName(busiest)),
          _tile('recap.generated', 'Generated', formatUtcInstant(recap.generatedAtUtcMs)),
        ],
      ),
      if (!empty) ...[
        _section('recap.top_tracks', 'Top tracks', [
          for (final e in recap.topTracks)
            (e.entity.title ?? 'Unknown title', e.entity.artist),
        ]),
        _section('recap.top_artists', 'Top artists', [
          for (final e in recap.topArtists) (e.entity.name, null),
        ]),
        _section('recap.top_albums', 'Top albums', [
          for (final e in recap.topAlbums)
            (e.entity.name ?? 'Unknown album', e.entity.artist),
        ]),
      ],
      if (recap.months.isNotEmpty)
        Column(
          key: const ValueKey('recap.months'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Text('By month', style: theme.titleMedium),
            for (final m in recap.months)
              Row(
                children: [
                  Expanded(child: Text(recapMonthName(m))),
                  Text(formatListeningTime(m.listeningSeconds)),
                ],
              ),
          ],
        ),
    ];
  }

  Widget _tile(String key, String label, String value) => Column(
    key: ValueKey(key),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      Text(value, style: Theme.of(context).textTheme.titleMedium),
    ],
  );

  Widget _section(String key, String title, List<(String, String?)> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      key: ValueKey(key),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        for (final (primary, secondary) in rows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(primary),
            subtitle: secondary == null ? null : Text(secondary),
          ),
      ],
    );
  }
}
