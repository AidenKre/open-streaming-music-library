import 'package:flutter/material.dart';
import 'package:frontend/ui/shell/glass.dart';

/// The floating top bar at a tab's root: two glass capsules (the title,
/// the top-bar actions) below the top safe area. The space between them is
/// empty, so taps there reach the content scrolling underneath.
class ShellTopBar extends StatelessWidget {
  const ShellTopBar({super.key, required this.title, required this.actions});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const capsule = BorderRadius.all(Radius.circular(28));
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            // The title takes the free space (left-aligned), so the
            // actions capsule sits at the right edge; the gap between them
            // stays pass-through (Align takes no hits itself).
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: GlassSurface(
                  borderRadius: capsule,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    // At least 48, growing with the text (audit 4B(b) F2).
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        heightFactor: 1,
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: theme.textTheme.titleLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (actions.isNotEmpty)
              GlassSurface(
                borderRadius: capsule,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
