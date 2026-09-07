import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/screens/widgets/recurrence_controls.dart';

Widget _accessibilityApp({RecurrenceRule? initialRule}) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(
    body: MediaQuery(
      data: const MediaQueryData(
        textScaler: TextScaler.linear(2),
        viewInsets: EdgeInsets.only(bottom: 300),
      ),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          RecurrenceEditor(
            start: DateTime(2026, 8, 12),
            initialRule: initialRule,
          ),
        ],
      ),
    ),
  ),
);

void _useSmallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('repeat controls keep semantics and 48px targets at 2x text', (
    tester,
  ) async {
    _useSmallViewport(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _accessibilityApp(
        initialRule: RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          weekdays: const <int>[3],
          end: RecurrenceEnd.count,
          count: 4,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(RecurrenceEditor), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('반복 요약')), findsOneWidget);
    expect(find.bySemanticsLabel('수요일'), findsOneWidget);
    for (final chip in tester.widgetList<FilterChip>(find.byType(FilterChip))) {
      expect(
        tester.getSize(find.byWidget(chip)).height,
        greaterThanOrEqualTo(48),
      );
    }
    for (final chip in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip))) {
      expect(
        tester.getSize(find.byWidget(chip)).height,
        greaterThanOrEqualTo(48),
      );
    }

    // Hardware keyboard input remains possible without relying on a pointer
    // target that may be below the keyboard inset.
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.tap(fields.first);
    await tester.enterText(fields.first, '2');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('scope dialog is scrollable and has accessible radio choices', (
    tester,
  ) async {
    _useSmallViewport(tester);
    EventEditScope? selected;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          textScaler: TextScaler.linear(2),
          viewInsets: EdgeInsets.only(bottom: 300),
        ),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  selected = await showRecurrenceScopeDialog(
                    context,
                    deleting: true,
                  );
                },
                child: const Text('반복 삭제'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('반복 삭제'));
    await tester.pumpAndSettle();
    expect(find.text('이번 일정만'), findsOneWidget);
    expect(find.text('이번 일정과 이후'), findsOneWidget);
    expect(find.text('전체 시리즈'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    for (final tile in tester.widgetList<RadioListTile<EventEditScope>>(
      find.byType(RadioListTile<EventEditScope>),
    )) {
      expect(
        tester.getSize(find.byWidget(tile)).height,
        greaterThanOrEqualTo(48),
      );
    }
    final dialogScroll = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('전체 시리즈'),
      240,
      scrollable: dialogScroll,
    );
    await tester.tap(find.text('전체 시리즈'));
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    expect(selected, EventEditScope.all);
    expect(tester.takeException(), isNull);
  });
}
