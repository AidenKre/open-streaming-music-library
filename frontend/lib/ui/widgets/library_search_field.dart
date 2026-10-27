import 'package:flutter/material.dart';

/// The search text field shared by the global Search page and the in-page
/// search on the root browse tabs. Owns its text controller; debouncing and
/// searching belong to `LibrarySearchController`, which the page feeds from
/// [onChanged] / [onCleared].
class LibrarySearchField extends StatefulWidget {
  const LibrarySearchField({
    super.key,
    required this.hintText,
    required this.onChanged,
    required this.onCleared,
    this.autofocus = false,
  });

  final String hintText;
  final ValueChanged<String> onChanged;

  /// The clear button was tapped (the field is already empty).
  final VoidCallback onCleared;
  final bool autofocus;

  @override
  State<LibrarySearchField> createState() => _LibrarySearchFieldState();
}

class _LibrarySearchFieldState extends State<LibrarySearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    setState(() {});
    widget.onCleared();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      decoration: InputDecoration(
        hintText: widget.hintText,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _controller.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear),
                tooltip: 'Clear search',
                onPressed: _clear,
              )
            : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onChanged: (value) {
        // Rebuild for the clear button's visibility.
        setState(() {});
        widget.onChanged(value);
      },
    );
  }
}
