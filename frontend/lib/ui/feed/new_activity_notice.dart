import 'package:flutter/material.dart';

/// A compact "something changed, refresh" notice. A pure view: the surface
/// supplies the [message], the optional [actionLabel] and what [onRefresh]
/// does. With an [actionLabel] the notice shows the message and a button;
/// without one the whole notice is a single button labelled by [message].
/// Announced to screen readers as a live region when it appears.
class NewActivityNotice extends StatelessWidget {
  const NewActivityNotice({
    super.key,
    required this.message,
    this.actionLabel,
    required this.onRefresh,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: colors.onSecondaryContainer,
    );
    final label = actionLabel;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    if (label == null) {
      return Semantics(
        liveRegion: true,
        button: true,
        label: message,
        onTap: onRefresh,
        excludeSemantics: true,
        child: Material(
          color: colors.secondaryContainer,
          shape: shape,
          child: InkWell(
            onTap: onRefresh,
            customBorder: shape,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(message, style: style),
            ),
          ),
        ),
      );
    }

    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: colors.secondaryContainer,
        shape: shape,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(message, style: style),
              TextButton(onPressed: onRefresh, child: Text(label)),
            ],
          ),
        ),
      ),
    );
  }
}
