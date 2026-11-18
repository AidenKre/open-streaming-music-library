// Pre-merge review A5-05: the server-address page runs one connect at a
// time. Enter in the address field bypasses the disabled button (a submit
// unfocuses the field; a person clicks back into it and presses Enter
// again), so the page itself must ignore a second submit while a connect
// runs.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/server_address_page.dart';

import 'browse_harness.dart' show teardownTree;

void main() {
  testWidgets('Enter twice while a connect runs starts one connect',
      (tester) async {
    final held = Completer<void>();
    final urls = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: ServerAddressPage(onConnect: (url) {
        urls.add(url);
        return held.future;
      }),
    ));
    await tester.enterText(find.byType(TextField), 'http://s:8000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(urls, ['http://s:8000']);

    held.complete();
    await tester.pump();
    // Usable again once the connect ended.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(urls, hasLength(2));
    await teardownTree(tester);
  });
}
