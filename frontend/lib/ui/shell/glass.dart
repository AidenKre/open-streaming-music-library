import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// The shell's floating-chrome surface (phase-4 §8): a blur bounded by its
/// own clip (BackdropFilter blurs only within its ancestor clip, so the
/// viewport is never blurred) under a tinted fill for legibility.
///
/// Reduced effects (accessibility: high contrast or reduced motion) drop the
/// blur for an opaque tint.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final BorderRadius borderRadius;

  /// Accessibility settings ask for less visual effect.
  static bool reducedEffects(BuildContext context) =>
      MediaQuery.highContrastOf(context) ||
      MediaQuery.disableAnimationsOf(context);

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).colorScheme.surfaceContainerHigh;
    // Ink from the chrome's buttons paints on this transparent Material,
    // above the tint.
    final content = Material(type: MaterialType.transparency, child: child);
    if (reducedEffects(context)) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: ColoredBox(color: tint, child: content),
      );
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(color: tint.withValues(alpha: 0.78), child: content),
      ),
    );
  }
}
