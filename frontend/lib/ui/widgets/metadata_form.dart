import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/metadata_edit.dart';

/// Resolves prefix suggestions for an autocomplete-backed field key.
typedef SuggestionsFor = Future<List<String>> Function(String key, String query);

/// Field keys whose text input is backed by library autocomplete.
const _autocompleteKeys = {'artist', 'album_artist', 'album', 'genre'};
const _intKeys = {'track_number', 'disc_number'};

/// A persistence-neutral editor for a track's editable metadata fields.
///
/// Driven entirely by [fields] (the capabilities-derived descriptors), a
/// [current] value lookup, and a [MetadataEdit] it mutates via [onChanged]. It
/// knows nothing of uuid, outbox, PATCH, or sync — the owning page decides what
/// to do with the resulting [MetadataEdit] and when to call [onSubmit]. This is
/// what lets bulk edit and Upload confirm-tags reuse the same form later.
class MetadataForm extends StatefulWidget {
  const MetadataForm({
    super.key,
    required this.fields,
    required this.current,
    required this.edit,
    required this.onChanged,
    required this.suggestionsFor,
  });

  final List<FieldDescriptor> fields;

  /// Stored value for a field key (the track's current value).
  final Object? Function(String key) current;

  final MetadataEdit edit;
  final ValueChanged<MetadataEdit> onChanged;
  final SuggestionsFor suggestionsFor;

  @override
  State<MetadataForm> createState() => _MetadataFormState();
}

class _MetadataFormState extends State<MetadataForm> {
  final Map<String, Timer> _debounce = {};

  @override
  void dispose() {
    for (final t in _debounce.values) {
      t.cancel();
    }
    super.dispose();
  }

  String _initialText(FieldDescriptor f) {
    final value = widget.edit.effective(f.key, widget.current(f.key));
    return value?.toString() ?? '';
  }

  void _setText(String key, String raw) {
    // Empty text means "cleared" (an explicit null), distinct from untouched.
    widget.onChanged(widget.edit.set(key, raw.isEmpty ? null : raw));
  }

  void _setInt(String key, String raw) {
    final trimmed = raw.trim();
    widget.onChanged(
      widget.edit.set(key, trimmed.isEmpty ? null : int.tryParse(trimmed)),
    );
  }

  /// Debounced suggestion lookup so a fast typist doesn't issue a query per
  /// keystroke. A superseded lookup resolves empty rather than leaking.
  Future<Iterable<String>> _suggest(String key, String query) {
    _debounce[key]?.cancel();
    if (query.trim().isEmpty) return Future.value(const Iterable<String>.empty());
    final completer = Completer<Iterable<String>>();
    _debounce[key] = Timer(const Duration(milliseconds: 250), () async {
      completer.complete(await widget.suggestionsFor(key, query));
    });
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in widget.fields)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _buildField(field),
          ),
      ],
    );
  }

  Widget _buildField(FieldDescriptor field) {
    if (_intKeys.contains(field.key) || field.valueType == 'int' ||
        field.valueType == 'year') {
      return _IntField(
        key: ValueKey('field_${field.key}'),
        label: field.label,
        initial: _initialText(field),
        // A year is capped at 4 digits (max 9999) to match the backend's
        // accepted range, so an over-long year can't 422 on flush.
        maxDigits: field.valueType == 'year' ? 4 : null,
        onChanged: (raw) => _setInt(field.key, raw),
      );
    }
    if (_autocompleteKeys.contains(field.key)) {
      return _AutocompleteField(
        key: ValueKey('field_${field.key}'),
        label: field.label,
        initial: _initialText(field),
        optionsBuilder: (q) => _suggest(field.key, q),
        onChanged: (raw) => _setText(field.key, raw),
      );
    }
    return TextFormField(
      key: ValueKey('field_${field.key}'),
      initialValue: _initialText(field),
      decoration: InputDecoration(
        labelText: field.label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (raw) => _setText(field.key, raw),
    );
  }
}

class _IntField extends StatelessWidget {
  const _IntField({
    super.key,
    required this.label,
    required this.initial,
    required this.onChanged,
    this.maxDigits,
  });

  final String label;
  final String initial;
  final ValueChanged<String> onChanged;

  /// Optional hard cap on the number of digits accepted (e.g. 4 for a year).
  final int? maxDigits;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: initial,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        if (maxDigits != null) LengthLimitingTextInputFormatter(maxDigits),
      ],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    );
  }
}

class _AutocompleteField extends StatelessWidget {
  const _AutocompleteField({
    super.key,
    required this.label,
    required this.initial,
    required this.optionsBuilder,
    required this.onChanged,
  });

  final String label;
  final String initial;
  final Future<Iterable<String>> Function(String query) optionsBuilder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: initial),
      optionsBuilder: (value) => optionsBuilder(value.text),
      onSelected: onChanged,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextFormField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          // Fires for both typing and option selection (selection sets the
          // controller text), keeping the MetadataEdit in sync either way.
          onChanged: onChanged,
        );
      },
    );
  }
}
