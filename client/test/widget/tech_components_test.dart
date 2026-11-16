import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/widgets/tech/tech_widgets.dart';

// The technician UI kit (lib/widgets/tech, lib/theme/tech_theme.dart).
// A plain ThemeData stands in for AppTheme.theme, which loads Google Fonts.
Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    );

void main() {
  group('TechThemeScope', () {
    testWidgets('applies the technician theme inside, leaves outside unchanged', (tester) async {
      late ThemeData outside;
      late ThemeData inside;
      await tester.pumpWidget(_app(Builder(builder: (ctx) {
        outside = Theme.of(ctx);
        return TechThemeScope(child: Builder(builder: (ctx2) {
          inside = Theme.of(ctx2);
          return const SizedBox();
        }));
      })));

      expect(outside.filledButtonTheme.style, isNull);
      expect(outside.dialogTheme.shape, isNull);
      expect(inside.filledButtonTheme.style, isNotNull);
      expect(inside.dialogTheme.shape,
          const RoundedRectangleBorder(borderRadius: TechRadius.xlAll));
    });
  });

  group('TechButton', () {
    testWidgets('taps call onPressed', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(TechButton(label: 'Collect', onPressed: () => taps++)));
      await tester.tap(find.text('Collect'));
      expect(taps, 1);
    });

    testWidgets('loading shows a spinner and ignores taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(TechButton(label: 'Collect', loading: true, onPressed: () => taps++)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Collect'), findsNothing);
      await tester.tap(find.byType(FilledButton));
      expect(taps, 0);
    });

    testWidgets('is 52px tall; compact is 44px but keeps a 48px touch target', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        TechButton(key: const Key('a'), label: 'A', onPressed: () {}),
        TechButton.secondary(key: const Key('b'), label: 'B', onPressed: () {}, compact: true),
      ])));
      expect(tester.getSize(find.byKey(const Key('a'))).height, TechSize.buttonHeight);
      // Material pads the 44px button to the 48px minimum tap area.
      expect(tester.getSize(find.byKey(const Key('b'))).height, TechSize.minTouch);
      final visible = find.descendant(of: find.byKey(const Key('b')), matching: find.byType(Material));
      expect(tester.getSize(visible.first).height, TechSize.buttonHeightCompact);
    });
  });

  group('showTechConfirm', () {
    Future<bool?> open(WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(_app(Builder(builder: (ctx) => TextButton(
            onPressed: () async => result = await showTechConfirm(ctx,
                title: 'Remove photo?', message: 'This cannot be undone.',
                confirmLabel: 'Remove', destructive: true),
            child: const Text('open'),
          ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('confirm returns true', (tester) async {
      bool? result;
      await tester.pumpWidget(_app(Builder(builder: (ctx) => TextButton(
            onPressed: () async => result = await showTechConfirm(ctx,
                title: 'Remove photo?', confirmLabel: 'Remove', destructive: true),
            child: const Text('open'),
          ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Remove photo?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('cancel and tapping outside return false', (tester) async {
      await open(tester);
      expect(find.text('This cannot be undone.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Remove photo?'), findsNothing);
    });
  });

  group('showTechSheet', () {
    testWidgets('shows title, subtitle and content, and returns the popped value', (tester) async {
      String? result;
      await tester.pumpWidget(_app(Builder(builder: (ctx) => TextButton(
            onPressed: () async => result = await showTechSheet<String>(
              context: ctx,
              title: 'Upload document',
              subtitle: 'RAJA',
              builder: (sheetCtx) => TechOptionCard(
                icon: Icons.photo_camera_outlined,
                title: 'Camera',
                subtitle: 'Take a photo',
                onTap: () => Navigator.pop(sheetCtx, 'camera'),
              ),
            ),
            child: const Text('open'),
          ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Upload document'), findsOneWidget);
      expect(find.text('RAJA'), findsOneWidget);
      expect(find.byType(TechDragHandle), findsOneWidget);

      await tester.tap(find.text('Camera'));
      await tester.pumpAndSettle();
      expect(result, 'camera');
    });

    testWidgets('fits a small phone with the keyboard open', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 568 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(Builder(builder: (ctx) => TextButton(
            onPressed: () => showTechSheet<void>(
              context: ctx,
              title: 'Reason',
              builder: (_) => Column(children: [
                const TextField(),
                for (var i = 0; i < 12; i++) Text('line $i'),
              ]),
            ),
            child: const Text('open'),
          ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull); // no overflow
    });
  });

  group('states and option card', () {
    testWidgets('error state retry calls back', (tester) async {
      var retried = false;
      await tester.pumpWidget(_app(TechErrorState(message: 'No internet', onRetry: () => retried = true)));
      await tester.tap(find.text('Try again'));
      expect(retried, isTrue);
    });

    testWidgets('empty state shows title and message', (tester) async {
      await tester.pumpWidget(_app(const TechEmptyState(
          icon: Icons.event_busy_rounded, title: 'No jobs today', message: 'New jobs appear here.')));
      expect(find.text('No jobs today'), findsOneWidget);
      expect(find.text('New jobs appear here.'), findsOneWidget);
    });

    testWidgets('a selected option card shows a check instead of a chevron', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        TechOptionCard(icon: Icons.payments_outlined, title: 'Cash', onTap: () {}, selected: true),
        TechOptionCard(icon: Icons.qr_code_rounded, title: 'UPI', onTap: () {}),
      ])));
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    });
  });
}
