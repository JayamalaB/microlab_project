import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';

// The customer UI kit (lib/widgets/customer, lib/theme/customer_theme.dart).
// A plain ThemeData stands in for AppTheme.theme, which loads Google Fonts.
Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    );

Widget _opener(String label, Future<void> Function(BuildContext) open) =>
    _app(Builder(builder: (ctx) => TextButton(onPressed: () => open(ctx), child: Text(label))));

void main() {
  group('CustomerThemeScope', () {
    testWidgets('themes only its subtree', (tester) async {
      late ThemeData outside, inside;
      await tester.pumpWidget(_app(Builder(builder: (ctx) {
        outside = Theme.of(ctx);
        return CustomerThemeScope(child: Builder(builder: (c2) {
          inside = Theme.of(c2);
          return const SizedBox();
        }));
      })));
      expect(outside.filledButtonTheme.style, isNull);
      expect(outside.inputDecorationTheme.border, isNull);
      expect(inside.filledButtonTheme.style, isNotNull);
      expect(inside.dialogTheme.shape, const RoundedRectangleBorder(borderRadius: CxRadius.xlAll));
    });

    test('type scale never goes below 11pt and keeps its order', () {
      final sizes = [
        CxText.pageTitle, CxText.sheetTitle, CxText.sectionTitle, CxText.cardTitle,
        CxText.body, CxText.bodySecondary, CxText.caption,
      ].map((s) => s.fontSize!).toList();
      for (var i = 1; i < sizes.length; i++) {
        expect(sizes[i], lessThanOrEqualTo(sizes[i - 1]));
      }
      expect(sizes.last, greaterThanOrEqualTo(11));
    });
  });

  group('CxButton', () {
    testWidgets('taps call onPressed', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(CxButton(label: 'Book now', onPressed: () => taps++)));
      await tester.tap(find.text('Book now'));
      expect(taps, 1);
    });

    testWidgets('loading shows a spinner and ignores taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(CxButton(label: 'Pay', loading: true, onPressed: () => taps++)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      expect(taps, 0);
    });

    testWidgets('is 50px tall; compact keeps a 48px touch target', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        CxButton(key: const Key('a'), label: 'A', onPressed: () {}),
        CxButton.secondary(key: const Key('b'), label: 'B', onPressed: () {}, compact: true),
      ])));
      expect(tester.getSize(find.byKey(const Key('a'))).height, CxSize.buttonHeight);
      expect(tester.getSize(find.byKey(const Key('b'))).height, CxSize.minTouch);
    });

    testWidgets('icon button exposes its tooltip', (tester) async {
      await tester.pumpWidget(_app(CxIconButton(icon: Icons.close, tooltip: 'Close', onPressed: () {})));
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(tester.getSize(find.byType(CxIconButton)).height, greaterThanOrEqualTo(44));
    });
  });

  group('popups', () {
    testWidgets('showCxConfirm returns true on confirm, false on cancel', (tester) async {
      bool? result;
      await tester.pumpWidget(_opener('open', (ctx) async =>
          result = await showCxConfirm(ctx, title: 'Remove test?', confirmLabel: 'Remove', destructive: true)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(result, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('image source picker returns the chosen source', (tester) async {
      CxImageSource? picked;
      await tester.pumpWidget(_opener('open', (ctx) async =>
          picked = await showCxImageSourcePicker(ctx, title: 'Upload prescription')));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Upload prescription'), findsOneWidget);
      expect(find.byType(CxDragHandle), findsOneWidget);
      await tester.tap(find.text('Gallery'));
      await tester.pumpAndSettle();
      expect(picked, CxImageSource.gallery);
    });

    testWidgets('sheet fits a small phone with the keyboard open', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 568 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_opener('open', (ctx) async => showCxSheet<void>(
            context: ctx,
            title: 'Location',
            builder: (_) => Column(children: [
              const TextField(),
              for (var i = 0; i < 14; i++) Text('row $i'),
            ]),
          )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('cards, chips and states', () {
    testWidgets('filter chip reports selection to screen readers and taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(CxFilterChip(label: 'Offers', selected: true, onTap: () => taps++)));
      await tester.tap(find.text('Offers'));
      expect(taps, 1);
      final sem = tester.widget<Semantics>(
          find.descendant(of: find.byType(CxFilterChip), matching: find.byType(Semantics)).first);
      expect(sem.properties.selected, isTrue);
      expect(sem.properties.button, isTrue);
    });

    testWidgets('price shows the struck-through original price', (tester) async {
      await tester.pumpWidget(_app(const CxPrice(price: '₹450', originalPrice: '₹600')));
      final original = tester.widget<Text>(find.text('₹600'));
      expect(original.style!.decoration, TextDecoration.lineThrough);
    });

    testWidgets('error state retry and empty state action call back', (tester) async {
      var retried = false, acted = false;
      await tester.pumpWidget(_app(Column(children: [
        Expanded(child: CxErrorState(onRetry: () => retried = true)),
        Expanded(child: CxEmptyState(icon: Icons.search_off, title: 'No tests found',
            actionLabel: 'Clear filters', onAction: () => acted = true)),
      ])));
      await tester.tap(find.text('Try again'));
      await tester.tap(find.text('Clear filters'));
      expect(retried, isTrue);
      expect(acted, isTrue);
    });
  });
}
