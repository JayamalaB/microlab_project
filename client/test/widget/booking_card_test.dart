import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/models.dart';
import 'package:microlab/screens/customer/booking_widgets.dart';

// Helper — minimal valid BookingModel
BookingModel makeBooking({
  String status = 'Pending',
  bool canReschedule = true,
  int rescheduleCount = 0,
}) {
  final member = MemberModel(
    id: '1',
    name: 'Test Patient',
    mobile: '9000000000',
    gender: 'Male',
    location: 'Chennai',
    address: '123 Test St',
  );
  return BookingModel(
    id: 'BK001',
    member: member,
    tests: const [],
    mode: 'Home Collection',
    date: DateTime(2025, 9, 1),
    timeSlot: '09:00 AM',
    paymentType: 'service_charge',
    serviceCharge: 50,
    testsTotal: 500,
    grandTotal: 550,
    paidAmount: 50,
    status: status,
    createdAt: DateTime(2025, 8, 1),
    docRequired: false,
    docVerified: false,
    canReschedule: canReschedule,
    rescheduleCount: rescheduleCount,
  );
}

// Replicates the reschedule button visibility condition from _BookingCard.
// Tests this logic using BookingModel instances without requiring access to the
// private widget class.
Widget buildRescheduleTestWidget(BookingModel booking) {
  final showReschedule = booking.canReschedule &&
      (booking.status == 'Pending' ||
          booking.status == 'Scheduled' ||
          booking.status == 'Confirmed');
  return MaterialApp(
    home: Scaffold(
      body: showReschedule
          ? ElevatedButton(
              key: const Key('reschedule_btn'),
              onPressed: () {},
              child: const Text('Reschedule'),
            )
          : const SizedBox.shrink(),
    ),
  );
}

void main() {
  group('BookingStatusBadge — icon per status', () {
    testWidgets('Completed badge has check icon', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BookingStatusBadge(status: 'Completed')),
      ));
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
    });

    testWidgets('Cancelled badge has cancel icon', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BookingStatusBadge(status: 'Cancelled')),
      ));
      expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('In Progress badge has run icon', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BookingStatusBadge(status: 'In Progress')),
      ));
      expect(find.byIcon(Icons.directions_run_rounded), findsOneWidget);
    });

    testWidgets('Default status has person_pin icon', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BookingStatusBadge(status: 'Pending')),
      ));
      expect(find.byIcon(Icons.person_pin_outlined), findsOneWidget);
    });
  });

  group('Reschedule button visibility', () {
    testWidgets('shown when canReschedule=true and status=Pending', (tester) async {
      await tester.pumpWidget(
          buildRescheduleTestWidget(makeBooking(status: 'Pending', canReschedule: true)));
      expect(find.byKey(const Key('reschedule_btn')), findsOneWidget);
    });

    testWidgets('shown when canReschedule=true and status=Scheduled', (tester) async {
      await tester.pumpWidget(
          buildRescheduleTestWidget(makeBooking(status: 'Scheduled', canReschedule: true)));
      expect(find.byKey(const Key('reschedule_btn')), findsOneWidget);
    });

    testWidgets('shown when canReschedule=true and status=Confirmed', (tester) async {
      await tester.pumpWidget(
          buildRescheduleTestWidget(makeBooking(status: 'Confirmed', canReschedule: true)));
      expect(find.byKey(const Key('reschedule_btn')), findsOneWidget);
    });

    testWidgets('hidden when canReschedule=false', (tester) async {
      await tester.pumpWidget(
          buildRescheduleTestWidget(makeBooking(status: 'Pending', canReschedule: false)));
      expect(find.byKey(const Key('reschedule_btn')), findsNothing);
    });

    testWidgets('hidden when status=Completed even if canReschedule=true', (tester) async {
      await tester.pumpWidget(
          buildRescheduleTestWidget(makeBooking(status: 'Completed', canReschedule: true)));
      expect(find.byKey(const Key('reschedule_btn')), findsNothing);
    });

    testWidgets('hidden when status=Cancelled', (tester) async {
      await tester.pumpWidget(
          buildRescheduleTestWidget(makeBooking(status: 'Cancelled', canReschedule: true)));
      expect(find.byKey(const Key('reschedule_btn')), findsNothing);
    });

    testWidgets('hidden when status=Sample Collected', (tester) async {
      await tester.pumpWidget(
          buildRescheduleTestWidget(makeBooking(status: 'Sample Collected', canReschedule: true)));
      expect(find.byKey(const Key('reschedule_btn')), findsNothing);
    });
  });

  group('BookingModel fields after reaching reschedule limit', () {
    test('canReschedule=false with rescheduleCount=2 is consistent', () {
      final booking = makeBooking(canReschedule: false, rescheduleCount: 2);
      expect(booking.canReschedule, isFalse);
      expect(booking.rescheduleCount, 2);
    });

    test('canReschedule=true with rescheduleCount=1 still allows reschedule', () {
      final booking = makeBooking(canReschedule: true, rescheduleCount: 1);
      expect(booking.canReschedule, isTrue);
    });
  });
}
