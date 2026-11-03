import 'package:flutter/material.dart';
import 'package:frontend/ui/widgets/library_search_field.dart';

/// A feed's header. Generic: it knows no search copy policy, offline state
/// or history; the page supplies text, callbacks and (for [FeedHeader.live])
/// owns and disposes the text/focus state, reused by [LibrarySearchField]
/// so there is only ever one text owner.
class FeedHeader extends StatelessWidget {
  /// A search-looking button that navigates (Home -> Search).
  const FeedHeader.navigate({
    super.key,
    required VoidCallback this.onActivate,
    this.hintText = 'Search your library',
  }) : controller = null,
       focusNode = null,
       onChanged = null,
       onClear = null,
       onSubmitted = null,
       filterBar = null;

  /// An editable search field with immediate clear and an optional chip
  /// bar (Search).
  const FeedHeader.live({
    super.key,
    required TextEditingController this.controller,
    required FocusNode this.focusNode,
    required ValueChanged<String> this.onChanged,
    required VoidCallback this.onClear,
    this.onSubmitted,
    this.filterBar,
    this.hintText = 'Search your library',
  }) : onActivate = null;

  final VoidCallback? onActivate;
  final String hintText;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final ValueChanged<String>? onSubmitted;
  final Widget? filterBar;

  @override
  Widget build(BuildContext context) {
    final activate = onActivate;
    if (activate != null) {
      final colors = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Semantics(
          button: true,
          label: hintText,
          excludeSemantics: true,
          child: Material(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(28),
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: activate,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.search, color: colors.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        hintText,
                        style: TextStyle(color: colors.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: LibrarySearchField(
            hintText: hintText,
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged!,
            onSubmitted: onSubmitted,
            onCleared: onClear!,
          ),
        ),
        ?filterBar,
      ],
    );
  }
}
