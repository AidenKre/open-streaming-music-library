import 'package:flutter/material.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';

/// The banners above the mini player. Each banner decides its own
/// visibility; their MEASURED heights tell the region whether it fits in
/// [maxHeight]. When it doesn't, the region is capped, scrolls, and shows a
/// 'Notifications (n)' label counting the banners actually shown.
class ShellBannerRegion extends StatefulWidget {
  const ShellBannerRegion({
    super.key,
    required this.maxHeight,
    required this.banners,
  });

  final double maxHeight;
  final List<Widget> banners;

  @override
  State<ShellBannerRegion> createState() => _ShellBannerRegionState();
}

class _ShellBannerRegionState extends State<ShellBannerRegion> {
  final _heights = <Key, double>{};

  Key _keyOf(Widget banner) => ValueKey(banner.runtimeType);

  @override
  Widget build(BuildContext context) {
    final shown = {for (final b in widget.banners) _keyOf(b)};
    _heights.removeWhere((k, _) => !shown.contains(k));
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final banner in widget.banners)
          MeasuredSize(
            key: _keyOf(banner),
            onChange: (size) {
              if (mounted) {
                setState(() => _heights[_keyOf(banner)] = size.height);
              }
            },
            child: banner,
          ),
      ],
    );
    final total = _heights.values.fold<double>(0, (a, b) => a + b);
    if (total <= widget.maxHeight) return content;
    final count = _heights.values.where((h) => h > 0).length;
    final theme = Theme.of(context);
    return SizedBox(
      height: widget.maxHeight,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              child: Text(
                'Notifications ($count)',
                style: theme.textTheme.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              child: SingleChildScrollView(primary: false, child: content),
            ),
          ],
        ),
      ),
    );
  }
}
