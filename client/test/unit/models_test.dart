import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/models.dart';

void main() {
  // ─── TestModel ────────────────────────────────────────────────────────────────

  group('TestModel.fromJson', () {
    test('parses test with active offer using discount_percent', () {
      final json = {
        'id': '42',
        'name': 'CBC',
        'type': 'single',
        'category': 'Haematology',
        'description': 'Complete Blood Count',
        'offer': 'yes',
        'original_price': '500',
        'final_price': '375',
        'discount_percent': '25',
        'doc_req': 0,
        'report_sts': 'available',
      };
      final model = TestModel.fromJson(json);
      expect(model.id, '42');
      expect(model.name, 'CBC');
      expect(model.type, 'single');
      expect(model.hasOffer, isTrue);
      expect(model.originalPrice, 500.0);
      expect(model.finalPrice, 375.0);
      expect(model.offerPercent, 25.0);
      expect(model.docRequired, isFalse);
      expect(model.reportStatus, 'available');
    });

    test('parses test with offer using offer_percent key', () {
      final json = {
        'id': '5',
        'name': 'Thyroid',
        'type': 'single',
        'category': '',
        'description': '',
        'offer': 'yes',
        'original_price': '1000',
        'final_price': '800',
        'offer_percent': '20',
        'doc_req': 0,
        'report_sts': '',
      };
      expect(TestModel.fromJson(json).offerPercent, 20.0);
    });

    test('parses test with offer using offer_pct key', () {
      final json = {
        'id': '5',
        'name': 'Panel',
        'type': 'package',
        'category': '',
        'description': '',
        'offer': 'yes',
        'original_price': '2000',
        'final_price': '1500',
        'offer_pct': '25',
        'doc_req': 0,
        'report_sts': '',
      };
      expect(TestModel.fromJson(json).offerPercent, 25.0);
    });

    test('no offer — hasOffer false, offerPercent null', () {
      final json = {
        'id': '7',
        'name': 'Thyroid Panel',
        'type': 'package',
        'category': 'Endocrinology',
        'description': '',
        'offer': 'no',
        'original_price': '1200',
        'final_price': '1200',
        'doc_req': 0,
        'report_sts': 'pending',
      };
      final model = TestModel.fromJson(json);
      expect(model.hasOffer, isFalse);
      expect(model.offerPercent, isNull);
    });

    test('falls back to original_price when final_price is empty string', () {
      // The ?? '0' guard means a *missing* key yields 0.0, not original_price.
      // Only an empty/invalid string triggers the null from tryParse → fallback.
      final json = {
        'id': '1',
        'name': 'Test',
        'type': 'single',
        'category': '',
        'description': '',
        'offer': 'no',
        'original_price': '300',
        'final_price': '',
        'doc_req': 0,
        'report_sts': '',
      };
      expect(TestModel.fromJson(json).finalPrice, 300.0);
    });

    test('missing final_price key yields 0.0 (not original_price)', () {
      final json = {
        'id': '1',
        'name': 'Test',
        'type': 'single',
        'category': '',
        'description': '',
        'offer': 'no',
        'original_price': '300',
        'doc_req': 0,
        'report_sts': '',
      };
      expect(TestModel.fromJson(json).finalPrice, 0.0);
    });

    test('falls back to package_id when id absent', () {
      final json = {
        'package_id': '99',
        'name': 'Package',
        'type': 'package',
        'category': '',
        'description': '',
        'offer': 'no',
        'original_price': '0',
        'doc_req': 0,
        'report_sts': '',
      };
      expect(TestModel.fromJson(json).id, '99');
    });

    test('doc_req int 1 → docRequired true', () {
      final base = {'id': '1', 'name': 'X', 'type': 'single', 'category': '', 'description': '', 'offer': 'no', 'original_price': '0', 'report_sts': ''};
      expect(TestModel.fromJson({...base, 'doc_req': 1}).docRequired, isTrue);
    });

    test('doc_req bool true → docRequired true', () {
      final base = {'id': '1', 'name': 'X', 'type': 'single', 'category': '', 'description': '', 'offer': 'no', 'original_price': '0', 'report_sts': ''};
      expect(TestModel.fromJson({...base, 'doc_req': true}).docRequired, isTrue);
    });

    test('doc_req string yes → docRequired true', () {
      final base = {'id': '1', 'name': 'X', 'type': 'single', 'category': '', 'description': '', 'offer': 'no', 'original_price': '0', 'report_sts': ''};
      expect(TestModel.fromJson({...base, 'doc_req': 'yes'}).docRequired, isTrue);
    });

    test('doc_req 0 → docRequired false', () {
      final base = {'id': '1', 'name': 'X', 'type': 'single', 'category': '', 'description': '', 'offer': 'no', 'original_price': '0', 'report_sts': ''};
      expect(TestModel.fromJson({...base, 'doc_req': 0}).docRequired, isFalse);
    });

    test('uses despt as description fallback', () {
      final json = {
        'id': '1',
        'name': 'Test',
        'type': 'single',
        'category': '',
        'despt': 'Fallback description',
        'offer': 'no',
        'original_price': '0',
        'doc_req': 0,
        'report_sts': '',
      };
      expect(TestModel.fromJson(json).description, 'Fallback description');
    });

    test('empty pre_instrs becomes null', () {
      final json = {
        'id': '1', 'name': 'T', 'type': 'single', 'category': '', 'description': '',
        'offer': 'no', 'original_price': '0', 'doc_req': 0, 'report_sts': '',
        'pre_instrs': '',
      };
      expect(TestModel.fromJson(json).preInstructions, isNull);
    });

    test('non-empty pre_instrs preserved', () {
      final json = {
        'id': '1', 'name': 'T', 'type': 'single', 'category': '', 'description': '',
        'offer': 'no', 'original_price': '0', 'doc_req': 0, 'report_sts': '',
        'pre_instrs': 'Fast for 8 hours',
      };
      expect(TestModel.fromJson(json).preInstructions, 'Fast for 8 hours');
    });
  });

  // ─── BranchModel ──────────────────────────────────────────────────────────────

  group('BranchModel.fromJson', () {
    test('parses all fields', () {
      final json = {
        'branchId': 3,
        'name': 'Main Branch',
        'address': '123 Main St',
        'location': 'Chennai',
        'pincode': '600001',
        'mobileNo': '9876543210',
        'telephoneNo': '044-12345678',
        'email': 'branch@lab.com',
        'latitude': 13.0827,
        'longitude': 80.2707,
      };
      final model = BranchModel.fromJson(json);
      expect(model.id, '3');
      expect(model.name, 'Main Branch');
      expect(model.address, '123 Main St');
      expect(model.location, 'Chennai');
      expect(model.pincode, '600001');
      expect(model.mobileNo, '9876543210');
      expect(model.telephoneNo, '044-12345678');
      expect(model.email, 'branch@lab.com');
      expect(model.lat, closeTo(13.0827, 0.0001));
      expect(model.lng, closeTo(80.2707, 0.0001));
    });

    test('branchId as string is preserved', () {
      final json = {'branchId': '7', 'name': 'B', 'address': 'A'};
      expect(BranchModel.fromJson(json).id, '7');
    });

    test('missing optional fields are null', () {
      final json = {'branchId': 1, 'name': 'Branch A', 'address': 'Some address'};
      final model = BranchModel.fromJson(json);
      expect(model.location, isNull);
      expect(model.pincode, isNull);
      expect(model.mobileNo, isNull);
      expect(model.lat, isNull);
      expect(model.lng, isNull);
    });

    test('lat/lng parsed from int JSON numbers', () {
      final json = {'branchId': 1, 'name': 'B', 'address': 'A', 'latitude': 12, 'longitude': 80};
      final model = BranchModel.fromJson(json);
      expect(model.lat, 12.0);
      expect(model.lng, 80.0);
    });
  });

  // ─── PatientModel ─────────────────────────────────────────────────────────────

  group('PatientModel.fromJson', () {
    test('parses required fields', () {
      final json = {
        'patient_id': 101,
        'name': 'Arun Kumar',
        'gender': 'Male',
        'location': 'Chennai',
        'address': '45 Park Street',
      };
      final model = PatientModel.fromJson(json);
      expect(model.patientId, 101);
      expect(model.name, 'Arun Kumar');
      expect(model.gender, 'Male');
      expect(model.location, 'Chennai');
      expect(model.address, '45 Park Street');
    });

    test('parses optional fields when present', () {
      final json = {
        'patient_id': 5,
        'name': 'Priya',
        'gender': 'Female',
        'location': 'Bangalore',
        'address': 'B-12',
        'email': 'priya@example.com',
        'date_of_birth': '1990-05-15',
        'age': '34',
        'relation': 'Self',
        'health_condition': 'Diabetes',
        'mobile': '9876543210',
        'patient_id_ref': 'REF-001',
      };
      final model = PatientModel.fromJson(json);
      expect(model.email, 'priya@example.com');
      expect(model.dateOfBirth, '1990-05-15');
      expect(model.age, '34');
      expect(model.relation, 'Self');
      expect(model.healthCondition, 'Diabetes');
      expect(model.mobile, '9876543210');
      expect(model.patientIdRef, 'REF-001');
    });

    test('optional fields are null when absent', () {
      final json = {
        'patient_id': 1,
        'name': 'Test',
        'gender': 'Male',
        'location': 'City',
        'address': 'Address',
      };
      final model = PatientModel.fromJson(json);
      expect(model.email, isNull);
      expect(model.mobile, isNull);
      expect(model.relation, isNull);
      expect(model.healthCondition, isNull);
      expect(model.patientIdRef, isNull);
    });

    test('patient_id as double (float from API) converts to int', () {
      final json = {
        'patient_id': 42.0,
        'name': 'X',
        'gender': 'M',
        'location': 'L',
        'address': 'A',
      };
      expect(PatientModel.fromJson(json).patientId, 42);
    });
  });

  // ─── MemberModel.age ──────────────────────────────────────────────────────────

  group('MemberModel.age', () {
    MemberModel makeMember({DateTime? dob}) => MemberModel(
          id: '1',
          name: 'Test',
          mobile: '',
          gender: '',
          location: '',
          address: '',
          dob: dob,
        );

    test('returns null when dob is null', () {
      expect(makeMember().age, isNull);
    });

    test('calculates age correctly for exact birthday today', () {
      final today = DateTime.now();
      final dob = DateTime(today.year - 30, today.month, today.day);
      expect(makeMember(dob: dob).age, 30);
    });

    test('does not count birthday that has not occurred yet this year', () {
      final today = DateTime.now();
      // Birthday is tomorrow — hasn't turned 25 yet
      final tomorrow = today.add(const Duration(days: 1));
      final dob = DateTime(today.year - 25, tomorrow.month, tomorrow.day);
      expect(makeMember(dob: dob).age, 24);
    });

    test('counts birthday that already passed this year', () {
      final today = DateTime.now();
      final yesterday = today.subtract(const Duration(days: 1));
      final dob = DateTime(today.year - 25, yesterday.month, yesterday.day);
      expect(makeMember(dob: dob).age, 25);
    });

    test('newborn (dob today) returns 0', () {
      final today = DateTime.now();
      final dob = DateTime(today.year, today.month, today.day);
      expect(makeMember(dob: dob).age, 0);
    });
  });

  // ─── BookingModel defaults ────────────────────────────────────────────────────

  group('BookingModel constructor defaults', () {
    late BookingModel booking;

    setUp(() {
      final member = MemberModel(
        id: '1',
        name: 'Patient',
        mobile: '9000000000',
        gender: 'Male',
        location: 'Chennai',
        address: '',
      );
      booking = BookingModel(
        id: 'BK001',
        member: member,
        tests: const [],
        mode: 'Lab Visit',
        date: DateTime(2025, 8, 1),
        timeSlot: '08:00 AM',
        paymentType: 'full',
        serviceCharge: 50,
        testsTotal: 500,
        grandTotal: 550,
        paidAmount: 550,
        status: 'Pending',
        createdAt: DateTime(2025, 7, 28),
        docRequired: false,
        docVerified: false,
      );
    });

    test('canReschedule defaults to true', () => expect(booking.canReschedule, isTrue));
    test('rescheduleCount defaults to 0', () => expect(booking.rescheduleCount, 0));
    test('isVip defaults to false', () => expect(booking.isVip, isFalse));
    test('amountDue defaults to 0', () => expect(booking.amountDue, 0));
    test('prescriptionImages defaults to empty', () => expect(booking.prescriptionImages, isEmpty));
    test('selectedTechnician defaults to null', () => expect(booking.selectedTechnician, isNull));
    test('reportUrl defaults to null', () => expect(booking.reportUrl, isNull));
    test('refundStatus defaults to null', () => expect(booking.refundStatus, isNull));
  });

  group('BookingModel with explicit canReschedule=false', () {
    test('stores canReschedule false and rescheduleCount', () {
      final member = MemberModel(id: '1', name: 'P', mobile: '', gender: '', location: '', address: '');
      final booking = BookingModel(
        id: 'BK002',
        member: member,
        tests: const [],
        mode: 'Home Collection',
        date: DateTime(2025, 8, 1),
        timeSlot: '10:00 AM',
        paymentType: 'service_charge',
        serviceCharge: 50,
        testsTotal: 300,
        grandTotal: 350,
        paidAmount: 50,
        status: 'Pending',
        createdAt: DateTime.now(),
        docRequired: false,
        docVerified: false,
        canReschedule: false,
        rescheduleCount: 2,
      );
      expect(booking.canReschedule, isFalse);
      expect(booking.rescheduleCount, 2);
    });
  });
}
