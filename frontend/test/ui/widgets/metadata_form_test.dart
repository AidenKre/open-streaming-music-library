import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/ui/widgets/metadata_form.dart';

void main() {
  testWidgets('year field caps input at 4 digits (max 9999)', (tester) async {
    var edit = const MetadataEdit.empty();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => MetadataForm(
              fields: const [
                FieldDescriptor(key: 'year', label: 'Year', valueType: 'year'),
              ],
              current: (_) => null,
              edit: edit,
              onChanged: (e) => setState(() => edit = e),
              suggestionsFor: (_, _) async => const [],
            ),
          ),
        ),
      ),
    );

    // A user pasting/typing an over-long year is truncated by the formatter
    // before it reaches the edit, so it can never 422 on flush.
    await tester.enterText(find.byType(TextField), '99999');
    await tester.pump();

    expect(edit.effective('year', null), 9999);
  });
}
