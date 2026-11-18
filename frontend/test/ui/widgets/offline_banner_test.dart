// Row 31 (owner, 2026-11-17): the offline banner says "Offline".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/ui/widgets/offline_banner.dart';

void main() {
  testWidgets('the offline banner reads "Offline"', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: OfflineBanner())),
    );
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Disconnected - Offline Mode'), findsNothing);
  });
}
