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
  final String? photoUrl;
  final bool isReadOnly;
  final String? patientIdRef;

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
    this.photoUrl,
    this.isReadOnly = false,
    this.patientIdRef,
  });

  int? get age {
    if (dob == null) return null;
    final today = DateTime.now();
    int a = today.year - dob!.year;
    if (today.month < dob!.month ||
        (today.month == dob!.month && today.day < dob!.day)) { a--; }
    return a;
  }
}

// ─── Patient Model ────────────────────────────────────────────────────────────

class PatientModel {
  final int patientId;
  final String? patientIdRef;
  final String name;
  final String gender;
  final String location;
  final String address;
  final String? email;
  final String? dateOfBirth;
  final String? age;
  final String? relation;
  final String? healthCondition;
  final String? photo;
  final String? mobile;

  const PatientModel({
    required this.patientId,
    this.patientIdRef,
    required this.name,
    required this.gender,
    required this.location,
    required this.address,
    this.email,
    this.dateOfBirth,
    this.age,
    this.relation,
    this.healthCondition,
    this.photo,
    this.mobile,
  });

  factory PatientModel.fromJson(Map<String, dynamic> j) {
    return PatientModel(
      patientId:       (j['patient_id'] as num).toInt(),
      patientIdRef:    j['patient_id_ref']?.toString(),
      name:            j['name'].toString(),
      gender:          j['gender'].toString(),
      location:        j['location'].toString(),
      address:         j['address'].toString(),
      email:           j['email']?.toString(),
      dateOfBirth:     j['date_of_birth']?.toString(),
      age:             j['age']?.toString(),
      relation:        j['relation']?.toString(),
      healthCondition: j['health_condition']?.toString(),
      photo:           j['photo']?.toString(),
      mobile:          j['mobile']?.toString(),
    );
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
  final String? preInstructions;

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
    this.preInstructions,
  });

  factory TestModel.fromJson(Map<String, dynamic> j) {
    final hasOffer = j['offer'] == 'yes';
    final original =
        double.tryParse(j['original_price']?.toString() ?? '0') ?? 0;
    final offerPct = hasOffer
        ? double.tryParse(
            (j['discount_percent'] ?? j['offer_percent'] ?? j['offer_pct'] ?? '0')
                .toString())
        : null;
    final finalP =
        double.tryParse(j['final_price']?.toString() ?? '0') ?? original;
    return TestModel(
      id: (j['id'] ?? j['package_id'])?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: j['name'] ?? '',
      type: j['type'] ?? 'single',
      category: j['category'] ?? '',
      description: j['description'] ?? j['despt'] ?? '',
      hasOffer: hasOffer,
      originalPrice: original,
      offerPercent: offerPct,
      finalPrice: finalP,
      docRequired: j['doc_req'] == 1 || j['doc_req'] == true || j['doc_req'] == 'yes',
      startDate: j['start_date']?.toString(),
      endDate: j['end_date']?.toString(),
      reportStatus: j['report_sts']?.toString() ?? '',
      preInstructions: j['pre_instrs']?.toString().isNotEmpty == true ? j['pre_instrs'].toString() : null,
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
  final double? lat;
  final double? lng;
  final bool    isFallback; // true when GPS lookup stepped down from the true nearest branch

  BranchModel({
    required this.id,
    required this.name,
    required this.address,
    this.location,
    this.pincode,
    this.mobileNo,
    this.telephoneNo,
    this.email,
    this.lat,
    this.lng,
    this.isFallback = false,
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
        lat:         (j['latitude']  as num?)?.toDouble(),
        lng:         (j['longitude'] as num?)?.toDouble(),
        isFallback:  j['isFallback']  as bool? ?? false,
      );
}

// ─── Booking Model ────────────────────────────────────────────────────────────

class BookingModel {
  final String id;
  final int? bookingIdNum;          // numeric DB booking_id for API calls
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
  final double amountDue;
  final String? paymentStatus;      // 'paid' | 'pending' | null
  final String status;
  final DateTime createdAt;
  final bool docRequired;
  final bool docVerified;
  final String? prescriptionStatus; // 'pending_review' | 'verified' | null
  final List<String> prescriptionImages;
  final bool isVip;
  final TechnicianModel? selectedTechnician;
  final String? reportUrl;
  final DateTime? reportReadyDate;
  final int? rating;
  final String? feedbackComment;
  final DateTime? feedbackDate;
  // Assigned technician info (from ip_technician_collection)
  final String? collectionStatus;   // 'assigned' | 'en_route' | 'arrived' | 'collected' | etc.
  final String? visitGroupId;       // non-null for family bookings sharing a visit
  final String? technicianName;
  final String? technicianMobile;
  final String? technicianPhoto;
  final int?    technicianId;       // ip_technicians.technician_id — needed for TrackingMapScreen
  final double? patientLat;         // collection_latitude  — patient's home coordinates
  final double? patientLng;         // collection_longitude
  final double? refundAmount;
  final String? refundStatus;       // 'pending' | 'processed' | 'none' | null
  final int rescheduleCount;
  final bool canReschedule;

  BookingModel({
    required this.id,
    this.bookingIdNum,
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
    this.amountDue = 0,
    this.paymentStatus,
    required this.status,
    required this.createdAt,
    required this.docRequired,
    required this.docVerified,
    this.prescriptionStatus,
    this.prescriptionImages = const [],
    this.isVip = false,
    this.selectedTechnician,
    this.reportUrl,
    this.reportReadyDate,
    this.rating,
    this.feedbackComment,
    this.feedbackDate,
    this.collectionStatus,
    this.visitGroupId,
    this.technicianName,
    this.technicianMobile,
    this.technicianPhoto,
    this.technicianId,
    this.patientLat,
    this.patientLng,
    this.refundAmount,
    this.refundStatus,
    this.rescheduleCount = 0,
    this.canReschedule = true,
  });
}

// ─── Time Slot ────────────────────────────────────────────────────────────────

class TimeSlot {
  final String id;
  final String label;
  final String time;
  final int?   parentSlotId; // ip_slots.slot_id — required by booking socket dispatch
  const TimeSlot({required this.id, required this.label, required this.time, this.parentSlotId});
}

// ─── Time Interval (appointment time within a slot) ───────────────────────────

class TimeInterval {
  final String time;        // "06:30" — sent to server
  final String label;       // "6:30 AM" — displayed to patient
  final bool   isAvailable;
  const TimeInterval({
    required this.time,
    required this.label,
    this.isAvailable = true,
  });
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
