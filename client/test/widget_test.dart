import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/screens/customer/booking_widgets.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  group('BookingStatusBadge', () {
    testWidgets('shows Completed text', (tester) async {
      await tester.pumpWidget(wrap(const BookingStatusBadge(status: 'Completed')));
      expect(find.text('Completed'), findsOneWidget);
    });

    testWidgets('shows Cancelled text', (tester) async {
      await tester.pumpWidget(wrap(const BookingStatusBadge(status: 'Cancelled')));
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('shows In Progress text', (tester) async {
      await tester.pumpWidget(wrap(const BookingStatusBadge(status: 'In Progress')));
      expect(find.text('In Progress'), findsOneWidget);
    });

    testWidgets('shows arbitrary status text', (tester) async {
      await tester.pumpWidget(wrap(const BookingStatusBadge(status: 'Pending')));
      expect(find.text('Pending'), findsOneWidget);
    });

    testWidgets('Completed uses check_circle icon', (tester) async {
      await tester.pumpWidget(wrap(const BookingStatusBadge(status: 'Completed')));
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('Cancelled uses cancel icon', (tester) async {
      await tester.pumpWidget(wrap(const BookingStatusBadge(status: 'Cancelled')));
      expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
    });

    testWidgets('In Progress uses directions_run icon', (tester) async {
      await tester.pumpWidget(wrap(const BookingStatusBadge(status: 'In Progress')));
      expect(find.byIcon(Icons.directions_run_rounded), findsOneWidget);
    });

    testWidgets('unknown status uses person_pin icon', (tester) async {
      await tester.pumpWidget(wrap(const BookingStatusBadge(status: 'Scheduled')));
      expect(find.byIcon(Icons.person_pin_outlined), findsOneWidget);
    });
  });
}
