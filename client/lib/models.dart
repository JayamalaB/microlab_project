import 'dart:typed_data';

// ─── Member Model ─────────────────────────────────────────────────────────────

class MemberModel {
  final String id;
  final String name;
  final String mobile;
  final String gender;
  final String location;
  final String address;
  final String? email;
  final DateTime? dob;
  final String? relation;
  final String? healthCondition;
  final Uint8List? photoBytes;

  MemberModel({
    required this.id,
    required this.name,
    required this.mobile,
    required this.gender,
    required this.location,
    required this.address,
    this.email,
    this.dob,
    this.relation,
    this.healthCondition,
    this.photoBytes,
  });

  int? get age {
    if (dob == null) return null;
    final today = DateTime.now();
    int a = today.year - dob!.year;
    if (today.month < dob!.month ||
        (today.month == dob!.month && today.day < dob!.day)) a--;
    return a;
  }
}

// ─── Test Model ───────────────────────────────────────────────────────────────

class TestModel {
  final String id;
  final String name;
  final String type; // 'single' | 'package'
  final String category;
  final String description;
  final bool hasOffer;
  final double originalPrice;
  final double? offerPercent;
  final double finalPrice;
  final bool docRequired;
  final String? startDate;
  final String? endDate;
  final String reportStatus;

  TestModel({
    required this.id,
    required this.name,
    required this.type,
    required this.category,
    required this.description,
    required this.hasOffer,
    required this.originalPrice,
    this.offerPercent,
    required this.finalPrice,
    required this.docRequired,
    this.startDate,
    this.endDate,
    required this.reportStatus,
  });

  factory TestModel.fromJson(Map<String, dynamic> j) {
    final hasOffer = j['offer'] == 'yes';
    final original = double.tryParse(j['original_price'] ?? '0') ?? 0;
    final offerPct = hasOffer
        ? double.tryParse(j['offer_percent'] ?? j['offer_pct'] ?? '0')
        : null;
    final finalP = double.tryParse(j['final_price'] ?? '0') ?? original;
    return TestModel(
      id: j['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: j['name'] ?? '',
      type: j['type'] ?? 'single',
      category: j['category'] ?? '',
      description: j['description'] ?? '',
      hasOffer: hasOffer,
      originalPrice: original,
      offerPercent: offerPct,
      finalPrice: finalP,
      docRequired: (j['doc_req'] ?? 'no') == 'yes',
      startDate: j['start_date'],
      endDate: j['end_date'],
      reportStatus: j['report_sts'] ?? '',
    );
  }
}

// ─── Branch Model ─────────────────────────────────────────────────────────────

class BranchModel {
  final String  id;
  final String  name;
  final String  address;
  final String? location;
  final String? pincode;
  final String? mobileNo;
  final String? telephoneNo;
  final String? email;

  BranchModel({
    required this.id,
    required this.name,
    required this.address,
    this.location,
    this.pincode,
    this.mobileNo,
    this.telephoneNo,
    this.email,
  });

  factory BranchModel.fromJson(Map<String, dynamic> j) => BranchModel(
        id:          j['branchId']?.toString() ?? '',
        name:        j['name']        as String? ?? '',
        address:     j['address']     as String? ?? '',
        location:    j['location']    as String?,
        pincode:     j['pincode']     as String?,
        mobileNo:    j['mobileNo']    as String?,
        telephoneNo: j['telephoneNo'] as String?,
        email:       j['email']       as String?,
      );
}

// ─── Booking Model ────────────────────────────────────────────────────────────

class BookingModel {
  final String id;
  final MemberModel member;
  final List<TestModel> tests;
  final String mode;
  final String? address;
  final String? pincode;
  final String? city;
  final BranchModel? branch;
  final DateTime date;
  final String timeSlot;
  final String paymentType; // 'service_charge' | 'full'
  final double serviceCharge;
  final double testsTotal;
  final double grandTotal;
  final double paidAmount;
  final String status;
  final DateTime createdAt;
  final bool docRequired;
  final bool docVerified;
  final bool isVip;
  final TechnicianModel? selectedTechnician;
  final String? reportUrl;        // download link from API
  final DateTime? reportReadyDate; // when report became available
  final int? rating;               // 1-5 stars; null = not yet rated
  final String? feedbackComment;
  final DateTime? feedbackDate;

  BookingModel({
    required this.id,
    required this.member,
    required this.tests,
    required this.mode,
    this.address,
    this.pincode,
    this.city,
    this.branch,
    required this.date,
    required this.timeSlot,
    required this.paymentType,
    required this.serviceCharge,
    required this.testsTotal,
    required this.grandTotal,
    required this.paidAmount,
    required this.status,
    required this.createdAt,
    required this.docRequired,
    required this.docVerified,
    this.isVip = false,
    this.selectedTechnician,
    this.reportUrl,
    this.reportReadyDate,
    this.rating,
    this.feedbackComment,
    this.feedbackDate,
  });
}

// ─── Time Slot ────────────────────────────────────────────────────────────────

class TimeSlot {
  final String id;
  final String label;
  final String time;
  const TimeSlot({required this.id, required this.label, required this.time});
}

// ─── Technician Model ─────────────────────────────────────────────────────────

class TechnicianModel {
  final String id;
  final String name;
  final String mobile;
  final double rating;       // 1.0–5.0
  final int totalReviews;
  final String experience;   // e.g. "4 years"
  final List<String> specializations;
  final bool available;
  final String? photoUrl;

  const TechnicianModel({
    required this.id,
    required this.name,
    required this.mobile,
    required this.rating,
    required this.totalReviews,
    required this.experience,
    required this.specializations,
    required this.available,
    this.photoUrl,
  });
}
