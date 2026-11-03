import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';

/// 4B.1 (phase-4 §8): the shell gives every nested surface its chrome
/// insets, measured from the ACTUAL laid-out bottom stack.
void main() {
  group('ShellChromeInsets', () {
    testWidgets('zero outside the shell', (tester) async {
      late EdgeInsets seen;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            seen = ShellChromeInsets.of(context);
            return const SizedBox();
          },
        ),
      );
      expect(seen, EdgeInsets.zero);
    });

    testWidgets('provides top/bottom to descendants, rebuilding them when '
        'the values change', (tester) async {
      final seen = <EdgeInsets>[];
      Widget host(double top, double bottom) => ShellChromeInsets(
        top: top,
        bottom: bottom,
        child: Builder(
          builder: (context) {
            seen.add(ShellChromeInsets.of(context));
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(host(56, 120));
      await tester.pumpWidget(host(56, 120)); // same: no rebuild needed
      await tester.pumpWidget(host(0, 80));
      expect(seen.first, const EdgeInsets.only(top: 56, bottom: 120));
      expect(seen.last, const EdgeInsets.only(bottom: 80));
    });
  });

  group('MeasuredSize', () {
    testWidgets('reports the laid-out size, then only real changes', (
      tester,
    ) async {
      final reports = <Size>[];
      Widget host(double h) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: MeasuredSize(
            onChange: reports.add,
            child: SizedBox(width: 100, height: h),
          ),
        ),
      );
      await tester.pumpWidget(host(64));
      await tester.pump();
      await tester.pumpWidget(host(64));
      await tester.pump();
      await tester.pumpWidget(host(100));
      await tester.pump();
      expect(reports, [const Size(100, 64), const Size(100, 100)]);
    });

    testWidgets('a child whose content grows (no new widget) is re-measured', (
      tester,
    ) async {
      final reports = <Size>[];
      final show = ValueNotifier(false);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: MeasuredSize(
              onChange: reports.add,
              child: ValueListenableBuilder<bool>(
                valueListenable: show,
                builder: (_, s, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s) const SizedBox(width: 10, height: 30),
                    const SizedBox(width: 10, height: 50),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      show.value = true;
      await tester.pump();
      await tester.pump();
      expect(reports.map((s) => s.height), [50, 80]);
    });
  });
}
