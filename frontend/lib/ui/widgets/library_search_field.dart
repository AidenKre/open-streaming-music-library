import 'package:flutter/material.dart';

/// The search text field shared by the global Search page and the in-page
/// search on the root browse tabs. Debouncing and searching belong to
/// `LibrarySearchController`, which the page feeds from [onChanged] /
/// [onSubmitted] / [onCleared].
///
/// Owns its text unless the page passes a [controller]; the clear button
/// follows the controller either way, so a page can set or clear the text
/// itself.
class LibrarySearchField extends StatefulWidget {
  const LibrarySearchField({
    super.key,
    required this.hintText,
    required this.onChanged,
    required this.onCleared,
    this.onSubmitted,
    this.autofocus = false,
    this.controller,
    this.focusNode,
  });

  final String hintText;
  final ValueChanged<String> onChanged;

  /// The keyboard's search action, with the current text.
  final ValueChanged<String>? onSubmitted;

  /// The clear button was tapped (the field is already empty).
  final VoidCallback onCleared;
  final bool autofocus;

  /// The page's text owner, when it needs to read or set the query itself.
  final TextEditingController? controller;

  /// The page's focus owner, when it needs to move focus itself.
  final FocusNode? focusNode;

  @override
  State<LibrarySearchField> createState() => _LibrarySearchFieldState();
}

class _LibrarySearchFieldState extends State<LibrarySearchField> {
  TextEditingController? _ownController;

  TextEditingController get _controller => widget.controller ?? _ownController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _ownController = TextEditingController();
  }

  @override
  void didUpdateWidget(LibrarySearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Like TextField: taking over from a page-owned controller keeps its
    // text; handing over to one drops ours.
    if (widget.controller == null && oldWidget.controller != null) {
      _ownController = TextEditingController.fromValue(
        oldWidget.controller!.value,
      );
    } else if (widget.controller != null && oldWidget.controller == null) {
      _ownController?.dispose();
      _ownController = null;
    }
  }

  @override
  void dispose() {
    _ownController?.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    widget.onCleared();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on every text change, typed or set by the page, for the clear
    // button's visibility.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => TextField(
        controller: _controller,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hintText,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: value.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                  onPressed: _clear,
                )
              : null,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}
